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
                     "usr/lib/wendyos-driver-activation.d",
                     "usr/lib/wendyos-driver-payloads/card/modules/test-kernel",
                     "sys/module/oldwifi",
                     "sys/module/cfg80211", "sys/bus/pci/devices/card", "bin"):
            (self.root / name).mkdir(parents=True)
        (self.root / "data/extensions/enabled/test-kernel/card.raw").touch()
        self.payload = self.root / "usr/lib/wendyos-driver-payloads/card"
        (self.payload / "modules/test-kernel/newwifi.ko").touch()
        (self.payload / "modules-load.conf").write_text("newwifi\n")
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
        fi
        if [ "${1:-}" = -- ] && [ "${2:-}" = "${FAIL_LOAD:-}" ]; then
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
        self.assertFalse((self.root / "usr/lib/modules/test-kernel/updates/wendyos/card").exists())

    def test_unrelated_install_does_not_reload(self):
        result, calls = self.run_apply("other")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(line.startswith(("modprobe -r", "systemctl")) for line in calls))

    def test_unload_failure_does_not_insert_mixed_stack(self):
        self.env["FAIL_UNLOAD"] = "cfg80211"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("prior modules restored", result.stderr)
        self.assertIn("modprobe -- oldwifi", calls)
        self.assertNotIn("modprobe -- newwifi", calls)
        self.assertFalse(any(line.startswith("systemctl") for line in calls))

    def test_load_failure_unexposes_payload_and_restores_old_stack(self):
        (self.payload / "firmware").mkdir()
        (self.payload / "firmware/card.bin").write_text("replacement")
        firmware = self.root / "usr/lib/firmware/card.bin"
        firmware.parent.mkdir(parents=True)
        firmware.write_text("base")
        self.env["FAIL_LOAD"] = "btusb"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("activation rolled back", result.stderr)
        self.assertIn("modprobe -r -- newwifi", calls)
        self.assertLess(calls.index("modprobe -- cfg80211"), calls.index("modprobe -- oldwifi"))
        self.assertFalse((self.root / "usr/lib/modules/test-kernel/updates/wendyos/card/newwifi.ko").exists())
        self.assertEqual(firmware.read_text(), "base")

    def test_external_holder_blocks_replacement_before_unload(self):
        holders = self.root / "sys/module/cfg80211/holders"
        holders.mkdir()
        (holders / "unexpected").touch()
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected depends on it", result.stderr)
        self.assertFalse(any(line.startswith("modprobe -r") for line in calls))

    def test_failed_rollback_reports_reboot_requirement(self):
        self.env["FAIL_LOAD"] = "btusb"
        self.env["FAIL_UNLOAD"] = "newwifi"
        result, _ = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rollback incomplete", result.stderr)
        self.assertIn("reboot required", result.stderr)

    def test_malformed_metadata_fails_before_module_changes(self):
        self.activation.write_text("replace invalid module\n")
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith(("modprobe", "systemctl")) for line in calls))

    def test_legacy_addon_loads_without_activation_metadata(self):
        self.activation.unlink()
        (self.root / "usr/lib/modules-load.d/card.conf").write_text("newwifi\n")
        for child in sorted(self.payload.rglob("*"), reverse=True):
            child.unlink() if child.is_file() else child.rmdir()
        self.payload.rmdir()
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("modprobe -- newwifi", calls)
        self.assertFalse(any(line.startswith(("modprobe -r", "systemctl")) for line in calls))

    def test_alphabetically_first_payload_wins_module_collision(self):
        (self.root / "data/extensions/enabled/test-kernel/zeta.raw").touch()
        zeta = self.root / "usr/lib/wendyos-driver-payloads/zeta"
        (zeta / "modules/test-kernel").mkdir(parents=True)
        (zeta / "modules/test-kernel/newwifi.ko").touch()
        (zeta / "modules-load.conf").write_text("newwifi\n")
        result, calls = self.run_apply("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("zeta conflicts with earlier package card", result.stderr)
        self.assertTrue((self.root / "usr/lib/modules/test-kernel/updates/wendyos/card/newwifi.ko").is_symlink())
        self.assertFalse((self.root / "usr/lib/modules/test-kernel/updates/wendyos/zeta").exists())
        self.assertEqual(calls.count("modprobe -- newwifi"), 1)

    def test_dash_and_underscore_module_names_collide(self):
        (self.payload / "modules/test-kernel/newwifi.ko").unlink()
        (self.payload / "modules/test-kernel/shared-name.ko").touch()
        (self.root / "data/extensions/enabled/test-kernel/zeta.raw").touch()
        zeta = self.root / "usr/lib/wendyos-driver-payloads/zeta/modules/test-kernel"
        zeta.mkdir(parents=True)
        (zeta / "shared_name.ko").touch()
        result, _ = self.run_apply("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("module:shared_name", result.stderr)

    def test_ineligible_earlier_payload_does_not_reserve_claims(self):
        (self.root / "sys/bus/pci/devices/card/device").write_text("0x1234\n")
        (self.root / "data/extensions/enabled/test-kernel/zeta.raw").touch()
        zeta = self.root / "usr/lib/wendyos-driver-payloads/zeta"
        (zeta / "modules/test-kernel").mkdir(parents=True)
        (zeta / "modules/test-kernel/newwifi.ko").touch()
        (zeta / "modules-load.conf").write_text("newwifi\n")
        result, calls = self.run_apply("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("modprobe -- newwifi", calls)
        self.assertTrue((self.root / "usr/lib/modules/test-kernel/updates/wendyos/zeta/newwifi.ko").is_symlink())


if __name__ == "__main__":
    unittest.main()
