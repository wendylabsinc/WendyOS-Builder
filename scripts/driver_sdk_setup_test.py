"""Exercise SDK relocation as the ordinary owner of readonly archived tools."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SETUP = Path(os.environ.get("WENDY_TEST_SDK_SETUP", str(ROOT / "recipes-kernel/wendyos-kernel-devkit/files/setup.sh")))


@unittest.skipIf(os.geteuid() == 0, "Run as an ordinary SDK owner to enforce file permissions")
class SDKSetupTests(unittest.TestCase):
    def fixture(self, sdk, fail=False):
        tools = ["runtime/lib/ld-linux-aarch64.so.1",
                 "toolchain/usr/bin/aarch64-poky-linux/aarch64-poky-linux-gcc",
                 "kernel-build/scripts/mod/modpost", "hosttools/mksquashfs"]
        for name in tools:
            path = sdk / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o555)
        library = sdk / "runtime/usr/lib/lib fixture.so"
        library.parent.mkdir(parents=True)
        library.write_bytes(b"\x7fELFreadonly runtime fixture")
        library.chmod(0o555)
        (sdk / "devkit.json").write_text(json.dumps(dict(
            cross_compile="aarch64-poky-linux-",
            toolchain_bindir="toolchain/usr/bin/aarch64-poky-linux",
            original_loader="/original/sysroot/lib/ld-linux-aarch64.so.1",
            kernel_version="fixture-kernel")))
        (sdk / "relocate_sdk.py").write_text(
            "import sys\nfrom pathlib import Path\n"
            + ("raise RuntimeError('fixture relocation failure')\n" if fail else "")
            + "assert '##DEFAULT_INSTALL_DIR##' == '/original/sysroot'\n"
            + "for name in sys.argv[3:]:\n"
            + "    with Path(name).open('r+b') as f:\n"
            + "        byte=f.read(1); f.seek(0); f.write(byte)\n")
        shutil.copyfile(SETUP, sdk / "setup.sh")
        return library

    def run_setup(self, sdk):
        return subprocess.run(["sh", str(sdk / "setup.sh")], cwd=sdk,
                              capture_output=True, text=True)

    def test_readonly_tools_and_runtime_relocate_and_setup_can_rerun(self):
        with tempfile.TemporaryDirectory(prefix="wendy SDK owner ") as tmp:
            sdk = Path(tmp) / "sdk"
            sdk.mkdir()
            library = self.fixture(sdk)
            before = library.read_bytes()
            self.assertFalse(os.access(library, os.W_OK))
            ignored = sdk / "toolchain/readonly-data"
            ignored.write_text("do not relocate")
            ignored.chmod(0o444)
            outside = Path(tmp) / "outside-executable"
            outside.write_text("outside SDK")
            outside.chmod(0o555)
            (sdk / "runtime/usr/lib/external-link").symlink_to(outside)
            for _ in range(2):
                result = self.run_setup(sdk)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("devkit ready", result.stdout)
            self.assertTrue(os.access(library, os.W_OK))
            self.assertEqual(library.read_bytes(), before)
            self.assertFalse(os.access(ignored, os.W_OK))
            self.assertFalse(os.access(outside, os.W_OK))
            self.assertIn("toolchain/usr/bin/aarch64-poky-linux", (sdk / "env.sh").read_text())

    def test_relocator_failure_is_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk = Path(tmp)
            self.fixture(sdk, fail=True)
            result = self.run_setup(sdk)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("fixture relocation failure", result.stderr)
            self.assertNotIn("devkit ready", result.stdout)
            self.assertFalse((sdk / "env.sh").exists())


if __name__ == "__main__":
    unittest.main()
