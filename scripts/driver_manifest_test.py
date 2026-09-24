"""Exercise the build/pack scripts' Python validators before shell serialization."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DriverManifestTests(unittest.TestCase):
    def validate(self, script, marker, manifest, machine="test-machine"):
        source = (ROOT / "scripts" / script).read_text()
        python = source.split(marker, 1)[1].split("\nPY", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "driver.json"
            path.write_text(json.dumps(manifest))
            return subprocess.run(["python3", "-", str(path), machine], input=python,
                                  text=True, capture_output=True, check=False)

    def firmware(self, path, **overrides):
        entry = dict(path=path, sha256="0" * 64, url="https://fixture.invalid/firmware")
        entry.update(overrides)
        return self.validate("build-driver.sh", 'FIRMWARE=$(python3 - "$MANIFEST" <<\'PY\'\n',
                             {"firmware": [entry]})

    def test_nul_cannot_become_parent_directory_in_bash(self):
        for path in [".\0./outside", "intel/.\0./.\0./outside", "safe\0name"]:
            with self.subTest(path=path):
                result = self.firmware(path)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("control characters", result.stderr)

    def test_unsafe_paths_and_controls_are_rejected(self):
        for path in ["", ".", "..", "../outside", "/outside", "intel/../../outside",
                     "intel/./fw", "intel//fw", "intel/", "intel/fw\n", "intel/fw\t", "intel/fw\r", "intel/fw\x7f"]:
            with self.subTest(path=path):
                self.assertNotEqual(self.firmware(path).returncode, 0)
        self.assertNotEqual(self.firmware("fw", url="https://fixture.invalid/\0fw").returncode, 0)

    def test_nested_firmware_path_round_trips(self):
        result = self.firmware("intel/ibt-0291-0291.sfi")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split("\t")[2], "intel/ibt-0291-0291.sfi\n")

    def test_service_options_are_rejected_at_pack_time(self):
        for unit in ["--help", "-H", "-host.service"]:
            result = self.validate("pack-sysext.sh", 'python3 - "$DRIVER/driver.json" "$MACHINE" > "$ACTIVATION_CONF" <<\'PY\'\n',
                                   {"activation": {"services_restart": [unit]}})
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_service_instance_remains_valid(self):
        result = self.validate("pack-sysext.sh", 'python3 - "$DRIVER/driver.json" "$MACHINE" > "$ACTIVATION_CONF" <<\'PY\'\n',
                               {"activation": {"services_restart": ["wpa_supplicant@wlan0.service"]}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "restart-service wpa_supplicant@wlan0.service\n")

    def test_be202_pi5_activation_replaces_onboard_wifi_and_restores_only_pci_wifi(self):
        manifest = json.loads((ROOT / "drivers/intel-be202/driver.json").read_text())
        marker = 'python3 - "$DRIVER/driver.json" "$MACHINE" > "$ACTIVATION_CONF" <<\'PY\'\n'
        for machine in ("raspberrypi5-wendyos", "raspberrypi5-nvme-wendyos"):
            with self.subTest(machine=machine):
                result = self.validate("pack-sysext.sh", marker, manifest, machine)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("replace brcmfmac_cyw\n", result.stdout)
                self.assertIn("replace brcmfmac\n", result.stdout)
                self.assertIn("restore-wifi-pci 8086:272b\n", result.stdout)
                self.assertNotIn("restore-wifi-connection wlan0", result.stdout)
        jetson = self.validate("pack-sysext.sh", marker, manifest,
                               "jetson-agx-thor-devkit-nvme-wendyos")
        self.assertEqual(jetson.returncode, 0, jetson.stderr)
        self.assertNotIn("brcmfmac", jetson.stdout)
        self.assertIn("restore-wifi-connection wlan0\n", jetson.stdout)
        self.assertNotIn("raspberry-pi-4", manifest["devices"])

    def test_invalid_wifi_restore_pci_id_is_rejected(self):
        result = self.validate("pack-sysext.sh",
                               'python3 - "$DRIVER/driver.json" "$MACHINE" > "$ACTIVATION_CONF" <<\'PY\'\n',
                               {"activation": {"wifi_pci_devices_restore": ["8086:wrong"]}})
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
