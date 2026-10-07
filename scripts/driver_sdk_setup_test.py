"""Check setup's permission handling, not ELF rewriting, as an ordinary SDK owner."""

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
SETUP = Path(os.environ.get("WENDY_TEST_SDK_SETUP", str(ROOT / "recipes-kernel/wendyos-kernel-devkit/files/setup.sh")))


@unittest.skipIf(os.geteuid() == 0, "Run as an ordinary SDK owner to enforce file permissions")
class SDKSetupTests(unittest.TestCase):
    def fixture(self, sdk, *, fail=False, misleading_access=False):
        tools = ["runtime/lib/ld-linux-aarch64.so.1",
                 "toolchain/usr/bin/aarch64-poky-linux/aarch64-poky-linux-gcc",
                 "kernel-build/scripts/mod/modpost", "hosttools/mksquashfs"]
        for name in tools:
            path = sdk / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o555)
        # The space checks argument handling in both chmod and relocation.
        library = sdk / "runtime/usr/lib/lib fixture.so"
        library.parent.mkdir(parents=True)
        library.write_bytes(b"\x7fELFreadonly runtime fixture")
        library.chmod(0o555)
        (sdk / "devkit.json").write_text(json.dumps(dict(
            cross_compile="aarch64-poky-linux-",
            toolchain_bindir="toolchain/usr/bin/aarch64-poky-linux",
            original_loader="/original/sysroot/lib/ld-linux-aarch64.so.1",
            kernel_version="fixture-kernel")))
        # Match oe-core relocate_sdk.py's permission sequence: loader-first open,
        # then access check, temporary chmod, open and mode restoration per tool.
        # The optional access lie models an observed Docker Desktop bind mount;
        # open() still uses real filesystem permissions so missing chmod fails.
        (sdk / "relocate_sdk.py").write_text(
            f"FAIL = {fail!r}\nMISLEADING_ACCESS = {misleading_access!r}\n"
            + textwrap.dedent('''\
                import json
                import os
                from pathlib import Path
                import stat
                import sys

                if FAIL:
                    raise RuntimeError('fixture relocation failure')
                assert '##DEFAULT_INSTALL_DIR##' == '/original/sysroot', 'prefix not substituted'
                with open(sys.argv[2], 'r+b') as loader:
                    loader.read(1)
                for name in sys.argv[3:]:
                    perms = os.stat(name).st_mode
                    accessible = os.access(name, os.W_OK | os.R_OK)
                    if MISLEADING_ACCESS and Path(name).name == 'lib fixture.so':
                        accessible = True
                    if accessible:
                        perms = None
                    else:
                        os.chmod(name, perms | stat.S_IRWXU)
                    with open(name, 'r+b') as f:
                        byte = f.read(1)
                        f.seek(0)
                        f.write(byte)
                    if perms is not None:
                        os.chmod(name, perms)
                with Path(__file__).with_name('relocated.jsonl').open('a') as trace:
                    trace.write(json.dumps(sys.argv[3:]) + '\\n')
                '''))
        shutil.copyfile(SETUP, sdk / "setup.sh")
        return [sdk / name for name in tools] + [library]

    def run_setup(self, sdk, *, env=None):
        return subprocess.run(["sh", str(sdk / "setup.sh")], cwd=sdk,
                              capture_output=True, text=True, env=env)

    def check_readonly_setup(self, *, misleading_access):
        with tempfile.TemporaryDirectory(prefix="wendy SDK owner ") as tmp:
            sdk = Path(tmp) / "sdk"
            sdk.mkdir()
            tools = self.fixture(sdk, misleading_access=misleading_access)
            before = {path: path.read_bytes() for path in tools}
            self.assertTrue(all(stat.S_IMODE(path.stat().st_mode) == 0o555 for path in tools))
            ignored = sdk / "toolchain/readonly-data"
            ignored.write_text("do not relocate")
            ignored.chmod(0o444)
            outside = Path(tmp) / "outside-executable"
            outside.write_text("outside SDK")
            outside.chmod(0o555)
            (sdk / "runtime/usr/lib/external-link").symlink_to(outside)
            for _ in range(2):
                trace = sdk / "relocated.jsonl"
                trace.unlink(missing_ok=True)
                result = self.run_setup(sdk)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("devkit ready", result.stdout)
                relocated = [name for batch in trace.read_text().splitlines()
                             for name in json.loads(batch)]
                self.assertCountEqual(relocated, [str(path) for path in tools])
            # Successful writes matter; persistent writability is not required by
            # the test contract (upstream may restore the original mode).
            self.assertEqual({path: path.read_bytes() for path in tools}, before)
            self.assertEqual(stat.S_IMODE(ignored.stat().st_mode), 0o444)
            self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o555)
            self.assertEqual(ignored.read_text(), "do not relocate")
            self.assertEqual(outside.read_text(), "outside SDK")
            self.assertIn("toolchain/usr/bin/aarch64-poky-linux", (sdk / "env.sh").read_text())

    def test_readonly_loader_and_tools_relocate_and_setup_can_rerun(self):
        self.check_readonly_setup(misleading_access=False)

    def test_misleading_access_check_does_not_prevent_relocation(self):
        self.check_readonly_setup(misleading_access=True)

    def assert_setup_failed(self, sdk, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("devkit ready", result.stdout)
        self.assertFalse((sdk / "env.sh").exists())

    def test_relocator_failure_is_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk = Path(tmp)
            self.fixture(sdk, fail=True)
            result = self.run_setup(sdk)
            self.assert_setup_failed(sdk, result)
            self.assertIn("fixture relocation failure", result.stderr)

    def test_loader_and_batch_chmod_failures_are_fatal(self):
        for target in ("runtime/lib/ld-linux-aarch64.so.1", "runtime/usr/lib/lib fixture.so"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                sdk = Path(tmp)
                self.fixture(sdk)
                wrappers = sdk / "wrappers"
                wrappers.mkdir()
                real_chmod = shutil.which("chmod")
                wrapper = wrappers / "chmod"
                wrapper.write_text(
                    f"#!{sys.executable}\nimport os, sys\n"
                    f"if {str(sdk / target)!r} in sys.argv[1:]:\n"
                    "    print('fixture chmod failure', file=sys.stderr)\n"
                    "    sys.exit(77)\n"
                    f"os.execv({real_chmod!r}, [{real_chmod!r}, *sys.argv[1:]])\n")
                wrapper.chmod(0o755)
                result = self.run_setup(sdk, env={**os.environ, "PATH": str(wrappers) + os.pathsep + os.environ["PATH"]})
                self.assert_setup_failed(sdk, result)
                self.assertIn("fixture chmod failure", result.stderr)
                self.assertFalse((sdk / "relocated.jsonl").exists())

    def test_traversal_failure_is_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk = Path(tmp)
            self.fixture(sdk)
            shutil.rmtree(sdk / "toolchain")
            result = self.run_setup(sdk)
            self.assert_setup_failed(sdk, result)
            self.assertIn("toolchain", result.stderr)


if __name__ == "__main__":
    unittest.main()
