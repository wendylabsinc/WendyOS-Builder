"""Exercise the build/pack scripts' Python validators before shell serialization."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from scripts.driver_supports_device import supports

ROOT = Path(__file__).resolve().parents[1]


class DriverManifestTests(unittest.TestCase):
    def validate(self, script, marker, manifest, device=""):
        source = (ROOT / "scripts" / script).read_text()
        python = source.split(marker, 1)[1].split("\nPY", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "driver.json"
            path.write_text(json.dumps(manifest))
            return subprocess.run(["python3", "-", str(path), device], input=python,
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

    def fetch(self, mirror_files, digest, upstream="https://fixture.invalid/firmware"):
        """Run build-driver.sh's fetch_firmware against a local mirror directory."""
        source = (ROOT / "scripts" / "build-driver.sh").read_text()
        function = "fetch_firmware() {" + source.split("fetch_firmware() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        with tempfile.TemporaryDirectory() as directory:
            mirror = Path(directory) / "mirror" / "sha256"
            mirror.mkdir(parents=True)
            for name, content in mirror_files.items():
                (mirror / name).write_bytes(content)
            destination = Path(directory) / "out" / "fw.bin"
            destination.parent.mkdir()
            script = ('set -euo pipefail\nerr() { echo "build-driver: $*" >&2; exit 1; }\n'
                      'FIRMWARE_MIRROR=$1\n' + function + 'fetch_firmware "$2" "$3" "$4"\n')
            result = subprocess.run(
                ["bash", "-c", script, "bash", "file://%s/mirror" % directory, upstream, digest, str(destination)],
                text=True, capture_output=True, check=False)
            return result, (destination.read_bytes() if destination.exists() else None)

    def test_mirrored_firmware_never_contacts_upstream(self):
        content = b"firmware"
        digest = hashlib.sha256(content).hexdigest()
        result, fetched = self.fetch({digest: content}, digest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fetched, content)
        self.assertIn("from mirror", result.stdout)

    def test_wrong_mirror_object_is_not_installed(self):
        digest = hashlib.sha256(b"firmware").hexdigest()
        result, fetched = self.fetch({digest: b"tampered"}, digest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(fetched)
        self.assertIn("using upstream", result.stderr)
        self.assertIn("cannot fetch firmware", result.stderr)

    def test_mirror_miss_falls_back_to_upstream(self):
        digest = hashlib.sha256(b"firmware").hexdigest()
        result, fetched = self.fetch({}, digest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(fetched)
        self.assertNotIn("using upstream", result.stderr)
        self.assertIn("cannot fetch firmware from https://fixture.invalid/firmware", result.stderr)

    def test_service_options_are_rejected_at_pack_time(self):
        for unit in ["--help", "-H", "-host.service"]:
            result = self.validate("pack-sysext.sh", 'python3 - "$DRIVER/driver.json" "$DEVICE" > "$ACTIVATION_CONF" <<\'PY\'\n',
                                   {"activation": {"services_restart": [unit]}})
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_service_instance_remains_valid(self):
        result = self.validate("pack-sysext.sh", 'python3 - "$DRIVER/driver.json" "$DEVICE" > "$ACTIVATION_CONF" <<\'PY\'\n',
                               {"activation": {"services_restart": ["wpa_supplicant@wlan0.service"]}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "restart-service wpa_supplicant@wlan0.service\n")

    def test_be202_pi5_activation_replaces_onboard_wifi_and_restores_only_pci_wifi(self):
        manifest = json.loads((ROOT / "drivers/intel-be202/driver.json").read_text())
        marker = 'python3 - "$DRIVER/driver.json" "$DEVICE" > "$ACTIVATION_CONF" <<\'PY\'\n'
        result = self.validate("pack-sysext.sh", marker, manifest, "raspberry-pi-5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pci 8086:272b\n", result.stdout)
        self.assertIn("replace brcmfmac_cyw\n", result.stdout)
        self.assertIn("replace brcmfmac\n", result.stdout)
        self.assertIn("restore-wifi-pci 8086:272b\n", result.stdout)
        self.assertNotIn("restore-wifi-connection wlan0", result.stdout)
        for device in ("jetson-agx-thor", "jetson-agx-orin", "jetson-agx-orin-emmc", "jetson-orin-nano"):
            with self.subTest(device=device):
                jetson = self.validate("pack-sysext.sh", marker, manifest, device)
                self.assertEqual(jetson.returncode, 0, jetson.stderr)
                self.assertNotIn("brcmfmac", jetson.stdout)
                self.assertIn("restore-wifi-connection wlan0\n", jetson.stdout)
        self.assertNotIn("raspberry-pi-4", manifest["devices"])

    def test_device_overrides_unloading_modules_keep_pci_guard(self):
        for path in sorted((ROOT / "drivers").glob("*/driver.json")):
            manifest = json.loads(path.read_text())
            for device, activation in manifest.get("activation_by_device", {}).items():
                with self.subTest(driver=path.parent.name, device=device):
                    if activation.get("modules_replace") or activation.get("modules_reload"):
                        self.assertTrue(activation.get("pci_devices"),
                                        "unloading device overrides must declare their PCI hardware guard")
                        result = self.validate("pack-sysext.sh",
                            'python3 - "$DRIVER/driver.json" "$DEVICE" > "$ACTIVATION_CONF" <<\'PY\'\n',
                            manifest, device)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        for pci_id in activation["pci_devices"]:
                            self.assertIn(f"pci {pci_id}\n", result.stdout)

    def test_device_overrides_require_device_identity(self):
        manifest = json.loads((ROOT / "drivers/intel-be202/driver.json").read_text())
        result = self.validate("pack-sysext.sh",
                               'python3 - "$DRIVER/driver.json" "$DEVICE" > "$ACTIVATION_CONF" <<\'PY\'\n',
                               manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("device ID required", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_invalid_device_overrides_are_rejected(self):
        for overrides in ([], {"bad/device": {}}, {"raspberry-pi-5": []}):
            with self.subTest(overrides=overrides):
                result = self.validate("pack-sysext.sh",
                                       'python3 - "$DRIVER/driver.json" "$DEVICE" > "$ACTIVATION_CONF" <<\'PY\'\n',
                                       {"activation_by_device": overrides}, "raspberry-pi-5")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("activation_by_device must map", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_an_alias_is_built_as_its_canonical_device(self):
        # Alias legs build with the canonical device's id, so per-device keys on an alias never apply.
        # Discover gates each leg on its own id, so listing only one of the two silently drops the other.
        artifacts = json.loads((ROOT / ".github/device-artifacts.json").read_text())
        aliases = {entry["manifest_alias"]: key.split("/")[0]
                   for key, entry in artifacts.items() if entry.get("manifest_alias")}
        for path in sorted((ROOT / "drivers").glob("*/driver.json")):
            manifest = json.loads(path.read_text())
            for alias, device in aliases.items():
                with self.subTest(driver=path.parent.name, alias=alias):
                    self.assertEqual(supports(manifest, alias), supports(manifest, device),
                                     f"list both {device} and {alias} in devices, or neither")
                    for key in ("variants_by_device", "activation_by_device"):
                        self.assertNotIn(alias, manifest.get(key, {}))

    def test_invalid_wifi_restore_pci_id_is_rejected(self):
        result = self.validate("pack-sysext.sh",
                               'python3 - "$DRIVER/driver.json" "$DEVICE" > "$ACTIVATION_CONF" <<\'PY\'\n',
                               {"activation": {"wifi_pci_devices_restore": ["8086:wrong"]}})
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
