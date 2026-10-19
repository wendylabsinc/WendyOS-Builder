"""Exercise recipe installs, clock ownership repair and early-boot unit ordering.

Run on Linux with systemd-analyze. The ownership test needs root; no test mounts
anything, starts a service or changes the system clock.
"""
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
UNITDIR = Path("usr/lib/systemd/system")


def install_recipe(name, root):
    recipe = REPO / "recipes-core" / name / f"{name}_1.0.bb"
    body = re.search(r"^do_install\(\) \{\n(.*?)^\}", recipe.read_text(), re.M | re.S)
    if body is None:
        raise AssertionError(f"missing install task in {recipe}")
    subprocess.run(["sh", "-eu", "-c", body[1]], check=True, env={
        **os.environ, "D": str(root), "UNPACKDIR": str(recipe.parent / "files"),
        "systemd_system_unitdir": "/" + str(UNITDIR),
    })
    return {p.relative_to(root) for p in root.rglob("*") if p.is_file()}


class TimesyncPersistenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_packages_have_no_overlapping_files(self):
        clock = install_recipe("systemd-mount-timesync", self.root / "clock")
        other = install_recipe("systemd-mount-wendy", self.root / "other")
        self.assertFalse(clock & other, f"conflicting package files: {clock & other}")
        self.assertEqual(clock, {
            UNITDIR / "var-lib-systemd-timesync.mount",
            UNITDIR / "wendyos-timesync-state.service",
            UNITDIR / "systemd-timesyncd.service.d/persist-clock.conf",
        })

    @unittest.skipUnless(os.geteuid() == 0, "ownership repair needs root")
    def test_prep_repairs_slot_uid_without_changing_saved_time(self):
        try:
            owner = pwd.getpwnam("systemd-timesync")
        except KeyError:
            self.skipTest("install systemd-timesyncd to supply its service user")
        state = self.root / "systemd-timesync"
        unit = (REPO / "recipes-core/systemd-mount-timesync/files/"
                "wendyos-timesync-state.service").read_text()
        commands = [shlex.split(line.removeprefix("ExecStart="))
                    for line in unit.splitlines() if line.startswith("ExecStart=")]

        def prepare():
            for command in commands:
                subprocess.run([str(state) if arg == "/data/systemd-timesync" else arg
                                for arg in command], check=True)

        prepare()  # First boot: let timesyncd create the timestamp itself.
        self.assertEqual(state.stat().st_uid, owner.pw_uid)
        self.assertEqual(state.stat().st_gid, owner.pw_gid)
        self.assertFalse((state / "clock").exists())
        clock = state / "clock"
        clock.touch()
        os.utime(clock, ns=(1786419819000000000, 1786419819000000000))
        stamp = clock.stat().st_mtime_ns
        # Directory already has this slot's UID but the file has another one:
        # merely fixing the directory does not repair this historical failure.
        os.chown(clock, owner.pw_uid + 1000, owner.pw_gid + 1000)
        prepare()
        self.assertEqual((clock.stat().st_uid, clock.stat().st_gid),
                         (owner.pw_uid, owner.pw_gid))
        self.assertEqual(clock.stat().st_mtime_ns, stamp)
        prepare()  # Repeated startup must preserve the saved timestamp too.
        self.assertEqual(clock.stat().st_mtime_ns, stamp)

    @unittest.skipUnless(os.geteuid() == 0, "directory preparation needs root")
    def test_service_can_prepare_rootfs_fallback(self):
        try:
            owner = pwd.getpwnam("systemd-timesync")
        except KeyError:
            self.skipTest("install systemd-timesyncd to supply its service user")
        state = self.root / "rootfs/var/lib/systemd/timesync"
        dropin = (REPO / "recipes-core/systemd-mount-timesync/files/"
                  "timesyncd-persist-clock.conf").read_text()
        commands = [shlex.split(line.removeprefix("ExecStartPre=+"))
                    for line in dropin.splitlines() if line.startswith("ExecStartPre=+")]
        self.assertTrue(commands)
        for command in commands:
            subprocess.run([str(state) if arg == "/var/lib/systemd/timesync" else arg
                            for arg in command], check=True)
        self.assertEqual((state.stat().st_uid, state.stat().st_gid),
                         (owner.pw_uid, owner.pw_gid))
        self.assertFalse((state / "clock").exists())

    @unittest.skipUnless(shutil.which("systemd-analyze"), "needs systemd-analyze")
    def test_early_boot_units_have_no_ordering_cycle(self):
        # Supply the host's standard target/sysusers dependencies in an isolated
        # root, then the actual shipped /data units and the recipe's output.
        shutil.copytree("/usr/lib/systemd/system", self.root / UNITDIR,
                        symlinks=True, dirs_exist_ok=True)
        (self.root / "lib").symlink_to("usr/lib")
        install_recipe("systemd-mount-timesync", self.root)
        for unit in ("recipes-core/data-mount/files/data.mount",
                     "recipes-support/data-device/files/wendyos-data.service"):
            shutil.copy(REPO / unit, self.root / UNITDIR / Path(unit).name)
        # Enable them as systemd.bbclass does: only the [Install] wants link pulls
        # the prep service into the data.mount transaction.
        subprocess.run(["systemctl", "--quiet", f"--root={self.root}", "enable",
                        "data.mount", "wendyos-data.service"], check=True)
        # verify checks executables exist but never runs them. Avoid depending
        # on target-specific /usr/sbin helpers being installed on the test host.
        for path in ("usr/bin/install", "usr/bin/chown", "usr/sbin/wendyos-data.sh",
                     "usr/lib/systemd/systemd-timesyncd", "bin/true"):
            executable = self.root / path
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.touch(mode=0o755)
        # Check our transaction with standard dependency ordering, while using
        # harmless stand-ins for distro-specific sysusers/remount executables.
        for name in ("systemd-sysusers.service", "systemd-remount-fs.service",
                     "systemd-udevd.service"):
            path = self.root / UNITDIR / name
            if path.exists():
                text = re.sub(r"^(Exec\w+)=.*$", r"\1=/bin/true", path.read_text(), flags=re.M)
                path.write_text(text)
        result = subprocess.run([
            "systemd-analyze", "verify", "--man=no", f"--root={self.root}",
            "systemd-timesyncd.service", "var-lib-systemd-timesync.mount",
            "wendyos-timesync-state.service",
        ], text=True, capture_output=True, env={**os.environ, "SYSTEMD_LOG_LEVEL": "debug"})
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        # Without the prep service in the transaction the cycle check is vacuous.
        self.assertIn("Installed new job wendyos-data.service/start", output)
        # Check the resolved dependencies, not just the drop-in text:
        # StateDirectory= can silently turn Wants= into an implicit Requires=.
        service = output.split("-> Unit systemd-timesyncd.service:", 1)[1].split("-> Unit ", 1)[0]
        self.assertRegex(service, r"Wants: var-lib-systemd-timesync\.mount")
        self.assertRegex(service, r"After: var-lib-systemd-timesync\.mount")
        self.assertNotRegex(service, r"(?:Requires|BindsTo): (?:var-lib-systemd-timesync\.mount|data\.mount|wendyos-timesync-state\.service)")


if __name__ == "__main__":
    unittest.main()
