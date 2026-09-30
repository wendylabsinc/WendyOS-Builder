import unittest

from scripts.driver_supports_device import supported_devices, supports


class DriverSupportsDeviceTests(unittest.TestCase):
    def test_omitted_devices_preserves_every_device_default(self):
        self.assertTrue(supports({"name": "legacy"}, "jetson-agx-thor"))

    def test_all_supports_every_device(self):
        self.assertTrue(supports({"devices": ["all"]}, "raspberry-pi-5"))

    def test_explicit_allowlist(self):
        manifest = {"devices": ["jetson-agx-thor", "jetson-agx-orin"]}
        self.assertTrue(supports(manifest, "jetson-agx-thor"))
        self.assertFalse(supports(manifest, "raspberry-pi-5"))

    def test_rejects_malformed_devices(self):
        for devices in ([], "all", [""], [7], ["all", "jetson-agx-thor"], ["x", "x"]):
            with self.subTest(devices=devices):
                with self.assertRaises(ValueError):
                    supported_devices({"devices": devices})


if __name__ == "__main__":
    unittest.main()
