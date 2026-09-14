"""Exercise the shipped apply script in an isolated filesystem with mock commands."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
APPLY = ROOT / "recipes-core/wendyos-sysext-apply/files/wendyos-sysext-apply.sh"


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("data/extensions/enabled/test-kernel", "run/extensions",
                     "usr/lib/modules-load.d", "usr/lib/extension-release.d",
                     "usr/lib/wendyos-driver-activation.d", "sys/module/oldwifi",
                     "sys/module/cfg80211", "sys/bus/pci/devices/card", "bin"):
            (self.root / name).mkdir(parents=True)
        (self.root / "data/extensions/enabled/test-kernel/card.raw").touch()
        (self.root / "usr/lib/modules-load.d/card.conf").write_text("newwifi\n")
        (self.root / "usr/lib/extension-release.d/extension-release.card").write_text(
            "WENDYOS_KERNEL=test-kernel\n")
        (self.root / "sys/bus/pci/devices/card/vendor").write_text("0x8086\n")
        (self.root / "sys/bus/pci/devices/card/device").write_text("0x272b\n")
        self.activation = self.root / "usr/lib/wendyos-driver-activation.d/card.conf"
        self.activation.write_text("pci 8086:272b\nreplace oldwifi\nreplace cfg80211\n"
                                   "reload btusb\nrestart-service wpa_supplicant.service\n")
        source = APPLY.read_text()
        for prefix in ("/data/extensions", "/run/", "/usr/lib/", "/sys/module/",
                       "/sys/bus/pci/devices/"):
            source = source.replace(prefix, str(self.root) + prefix)
        self.script = self.root / "apply.sh"
        self.script.write_text(source)
        self.log = self.root / "commands.log"
        mock = '''#!/bin/sh
cmd=${0##*/}
printf '%s %s\n' "$cmd" "$*" >> "$TEST_LOG"
case "$cmd" in
    uname) echo test-kernel ;;
    modprobe)
        if [ "${1:-}" = -r ] && [ "${3:-}" = "${FAIL_UNLOAD:-}" ]; then
            exit 1
        fi ;;
esac
exit 0
'''
        for name in ("uname", "systemd-sysext", "depmod", "udevadm", "modprobe",
                     "systemctl"):
            path = self.root / "bin" / name
            path.write_text(mock)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                        TEST_LOG=str(self.log), WENDYOS_SYSEXT_APPLY_LOCKED="1")

    def run_apply(self, subject="card"):
        result = subprocess.run(["sh", str(self.script), subject], env=self.env,
                                capture_output=True, text=True, check=False)
        calls = self.log.read_text().splitlines()
        return result, calls

    def test_replacement_order(self):
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        operations = [line for line in calls if line.startswith(("modprobe -r", "modprobe -- ", "systemctl"))]
        self.assertEqual(operations, ["modprobe -r -- oldwifi", "modprobe -r -- cfg80211",
                                     "modprobe -- newwifi", "modprobe -- btusb",
                                     "systemctl try-restart wpa_supplicant.service"])

    def test_absent_hardware_does_not_touch_modules_or_service(self):
        (self.root / "sys/bus/pci/devices/card/device").write_text("0x1234\n")
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(line.startswith(("modprobe", "systemctl")) for line in calls))

    def test_unrelated_install_does_not_reload(self):
        result, calls = self.run_apply("other")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(line.startswith(("modprobe -r", "systemctl")) for line in calls))

    def test_unload_failure_does_not_insert_mixed_stack(self):
        self.env["FAIL_UNLOAD"] = "cfg80211"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("replacement aborted", result.stderr)
        self.assertFalse(any(line.startswith(("modprobe -- ", "systemctl")) for line in calls))

    def test_malformed_metadata_fails_before_module_changes(self):
        self.activation.write_text("replace invalid module\n")
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith(("modprobe", "systemctl")) for line in calls))

    def test_legacy_addon_loads_without_activation_metadata(self):
        self.activation.unlink()
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("modprobe -- newwifi", calls)
        self.assertFalse(any(line.startswith(("modprobe -r", "systemctl")) for line in calls))


if __name__ == "__main__":
    unittest.main()
