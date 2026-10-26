"""Check device selection and native module closure staging."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.resolve_driver_manifest import resolve
from scripts.stage_native_driver import stage


ROOT = Path(__file__).resolve().parents[1]


class VariantTests(unittest.TestCase):
    def test_iq_uses_native_modules_and_nan_firmware(self):
        manifest = json.loads((ROOT / "drivers/intel-be202/driver.json").read_text())
        for device in ("dragonwing-iq-8275", "dragonwing-iq-9075"):
            resolved = resolve(manifest, device)
            self.assertEqual(resolved["build"]["kind"], "kernel-modules")
            self.assertEqual(resolved["patches"], [])
            self.assertEqual({entry["path"] for entry in resolved["firmware"]}, {
                "iwlwifi-gl-c0-fm-c0-c106.ucode", "iwlwifi-gl-c0-fm-c0.pnvm",
                "LICENCE.iwlwifi_firmware",
            })
            # Keep IQ below this kernel's c106 API ceiling, with the same
            # NAN-capable firmware and notice already pinned for Jetson.
            for entry in resolved["firmware"]:
                self.assertIn(entry, manifest["firmware"])
            self.assertTrue(resolved["source"]["devkit"])
        for device in ("jetson-agx-thor", "jetson-orin-nano", "raspberry-pi-5"):
            resolved = resolve(manifest, device)
            self.assertEqual(resolved["build"]["kind"], "backport-iwlwifi")
            self.assertEqual(resolved["firmware"][0]["path"], "iwlwifi-gl-c0-fm-c0-c107.ucode")
        self.assertEqual(manifest["build"]["kind"], "backport-iwlwifi")

    def test_missing_or_undeclared_identity_is_rejected(self):
        manifest = json.loads((ROOT / "drivers/intel-be202/driver.json").read_text())
        with self.assertRaisesRegex(ValueError, "device ID required"):
            resolve(manifest, "")
        manifest["variants_by_device"]["unknown"] = {"build": {}}
        with self.assertRaisesRegex(ValueError, "devices list"):
            resolve(manifest, "unknown")

    def test_variant_cannot_change_package_identity_or_activation(self):
        for key in ("name", "activation", "modules_load"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                resolve({"devices": ["board"], "variants_by_device": {"board": {key: "bad"}}}, "board")


class NativeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.devkit = self.root / "devkit"
        (self.devkit / "native-modules").mkdir(parents=True)
        (self.devkit / "native-firmware").mkdir()
        (self.devkit / "native-firmware/LICENCE").write_text("redistribution notice")
        self.index = {}
        for name, deps in (("card", ["bus"]), ("bus", []), ("unrelated", [])):
            data = (name + " module").encode()
            (self.devkit / "native-modules" / (name + ".ko")).write_bytes(data)
            self.index[name] = {"file": name + ".ko", "depends": deps,
                                "sha256": hashlib.sha256(data).hexdigest()}
        self.manifest = {"build": {"modules": ["card"], "firmware_from_devkit": True}}
        self.out = self.root / "build/src"

    def run_stage(self):
        (self.devkit / "native-modules/index.json").write_text(json.dumps(self.index))
        stage(self.devkit, self.manifest, self.out)

    def test_dependency_closure_and_notices_are_copied(self):
        self.run_stage()
        self.assertEqual({p.name for p in self.out.iterdir()}, {"card.ko", "bus.ko"})
        self.assertEqual((self.out.parent / "firmware/LICENCE").read_text(), "redistribution notice")

    def test_missing_dependency_fails(self):
        del self.index["bus"]
        with self.assertRaises(KeyError):
            self.run_stage()

    def test_corrupt_module_fails(self):
        (self.devkit / "native-modules/card.ko").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.run_stage()

    def test_index_cannot_escape_native_module_directory(self):
        self.index["card"]["file"] = "../outside.ko"
        with self.assertRaisesRegex(ValueError, "unsafe"):
            self.run_stage()


if __name__ == "__main__":
    unittest.main()
