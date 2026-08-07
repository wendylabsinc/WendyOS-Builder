from __future__ import annotations

import tempfile
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import check_bluetooth_stack as checker  # noqa: E402


def full_config(**overrides: str) -> dict[str, str]:
    config = {symbol: "m" for symbol in checker.MODULE_PACKAGES}
    config.update({symbol: "y" for symbol in checker.BUILTIN_SYMBOLS})
    config.update(overrides)
    return config


def full_packages(**overrides: str) -> dict[str, str]:
    packages = {checker.BLUEZ_PACKAGE: "5.86"}
    packages.update({package: "6.8.12" for package in checker.MODULE_PACKAGES.values()})
    packages.update({package: "1.0" for package in checker.REQUIRED_PACKAGES})
    packages.update(overrides)
    return packages


class BluezFloorTests(unittest.TestCase):
    def test_current_pin_passes(self):
        self.assertEqual(checker.validate_bluez({"bluez5": "5.86"}), [])

    def test_scarthgap_bluez_fails_the_floor(self):
        errors = checker.validate_bluez({"bluez5": "5.72"})
        self.assertTrue(any("older than" in error for error in errors))

    def test_missing_and_unparseable_bluez_are_reported(self):
        self.assertTrue(any("absent" in e for e in checker.validate_bluez({})))
        self.assertTrue(any("unparseable" in e for e in checker.validate_bluez({"bluez5": "git"})))


class FullProfileTests(unittest.TestCase):
    def test_clean_contract_image_passes(self):
        self.assertEqual(checker.validate_full_profile(full_config(), full_packages()), [])

    def test_builtin_symbols_need_no_module_packages(self):
        config = full_config(**{symbol: "y" for symbol in checker.MODULE_PACKAGES})
        packages = full_packages()
        for module_package in checker.MODULE_PACKAGES.values():
            packages.pop(module_package)
        self.assertEqual(checker.validate_full_profile(config, packages), [])

    def test_modular_symbol_without_package_is_reported(self):
        packages = full_packages()
        packages.pop("kernel-module-btusb")
        errors = checker.validate_full_profile(full_config(), packages)
        self.assertTrue(any("kernel-module-btusb" in error for error in errors))

    def test_bool_symbols_must_be_builtin(self):
        errors = checker.validate_full_profile(
            full_config(CONFIG_BT_HCIBTUSB_RTL="m"), full_packages()
        )
        self.assertTrue(any("CONFIG_BT_HCIBTUSB_RTL must resolve =y" in error for error in errors))

    def test_missing_firmware_or_blacklist_is_reported(self):
        for required in checker.REQUIRED_PACKAGES:
            packages = full_packages()
            packages.pop(required)
            errors = checker.validate_full_profile(full_config(), packages)
            self.assertTrue(any(required in error for error in errors), required)

    def test_vendor_packages_are_forbidden_in_any_spelling(self):
        for vendor in (
            "kernel-module-rtk-btusb",
            "nv-kernel-module-rtk-btusb",
            "nv-kernel-module-rtk-btusb-6.8.12-wendy",
            "tegra-firmware-rtl8822",
        ):
            errors = checker.validate_full_profile(full_config(), full_packages(**{vendor: "1.0"}))
            self.assertTrue(any(vendor in error for error in errors), vendor)


class MachineScopeTests(unittest.TestCase):
    def test_only_orin_nano_devkits_carry_the_full_profile(self):
        self.assertTrue(checker.machine_has_full_profile("jetson-orin-nano-devkit-nvme-wendyos"))
        self.assertTrue(checker.machine_has_full_profile("jetson-orin-nano-devkit-wendyos"))
        self.assertFalse(checker.machine_has_full_profile("jetson-agx-orin-devkit-wendyos"))
        self.assertFalse(checker.machine_has_full_profile("rpi5-wendyos"))

    def test_cli_floor_only_for_non_contract_machine(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "wendyos-image.manifest"
            manifest.write_text("bluez5 aarch64 5.86\n", encoding="utf-8")
            self.assertEqual(
                checker.main(["--machine", "rpi5-wendyos", "--manifest", str(manifest)]), 0
            )

    def test_cli_contract_machine_requires_config(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "wendyos-image.manifest"
            manifest.write_text("bluez5 aarch64 5.86\n", encoding="utf-8")
            self.assertEqual(
                checker.main(
                    ["--machine", "jetson-orin-nano-devkit-nvme-wendyos", "--manifest", str(manifest)]
                ),
                1,
            )

    def test_cli_parses_real_file_shapes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / ".config"
            manifest = root / "wendyos-image.manifest"
            config.write_text(
                "\n".join(f"{symbol}={state}" for symbol, state in full_config().items()) + "\n",
                encoding="utf-8",
            )
            manifest.write_text(
                "\n".join(f"{package} aarch64 {version}" for package, version in full_packages().items())
                + "\n",
                encoding="utf-8",
            )
            self.assertEqual(
                checker.main(
                    [
                        "--machine",
                        "jetson-orin-nano-devkit-nvme-wendyos",
                        "--manifest",
                        str(manifest),
                        "--config",
                        str(config),
                    ]
                ),
                0,
            )


class BluetoothLayerWiringTests(unittest.TestCase):
    def test_jp7_kernel_append_wires_the_contract(self):
        append = (
            REPO_ROOT
            / "meta-tegra-extensions-jp7/recipes-kernel/linux/linux-noble-nvidia-tegra_%.bbappend"
        ).read_text(encoding="utf-8")
        self.assertIn("require recipes-kernel/linux/wendy-bluetooth.inc", append)
        self.assertIn('WENDYOS_BLUETOOTH_ENABLE:jetson-orin-nano-devkit = "1"', append)
        self.assertIn("file://bluetooth-btusb-rtl.cfg", append)

    def test_fragments_cover_the_validator_symbols(self):
        core = (REPO_ROOT / "recipes-kernel/linux/files/bluetooth.cfg").read_text(encoding="utf-8")
        transport = (
            REPO_ROOT
            / "meta-tegra-extensions-jp7/recipes-kernel/linux/linux-noble-nvidia-tegra/bluetooth-btusb-rtl.cfg"
        ).read_text(encoding="utf-8")
        fragment_symbols = {
            line.split("=", 1)[0]
            for text in (core, transport)
            for line in text.splitlines()
            if line.startswith("CONFIG_") and "=" in line
        }
        self.assertTrue(set(checker.MODULE_PACKAGES).issubset(fragment_symbols))
        self.assertTrue(set(checker.BUILTIN_SYMBOLS).issubset(fragment_symbols))

    def test_machine_confs_remove_the_vendor_driver(self):
        for conf in (
            "conf/machine/jetson-orin-nano-devkit-nvme-wendyos.conf",
            "conf/machine/jetson-orin-nano-devkit-wendyos.conf",
        ):
            with self.subTest(conf=conf):
                text = (REPO_ROOT / conf).read_text(encoding="utf-8")
                self.assertIn('TEGRA_OOT_BLUETOOTH_DRIVERS = ""', text)
                self.assertIn("kernel-module-rtk-btusb", text)
                self.assertIn("tegra-firmware-rtl8822", text)

    def test_packagegroups_carry_runtime_halves(self):
        kernel_group = (
            REPO_ROOT / "recipes-core/packagegroups/packagegroup-wendyos-kernel.bb"
        ).read_text(encoding="utf-8")
        base_group = (
            REPO_ROOT / "recipes-core/packagegroups/tegra-packagegroup-base.inc"
        ).read_text(encoding="utf-8")
        self.assertIn('WENDYOS_BLUETOOTH_ENABLE:jetson-orin-nano-devkit = "1"', kernel_group)
        self.assertIn("kernel-module-btrtl", kernel_group)
        self.assertIn("linux-firmware-rtl8822", base_group)
        self.assertIn("rtk-btusb-blacklist", base_group)

    def test_blacklist_recipe_blocks_both_vendor_modules(self):
        conf = (
            REPO_ROOT
            / "meta-tegra-extensions/recipes-kernel/rtk-btusb-blacklist/rtk-btusb-blacklist/rtk-btusb-blacklist.conf"
        ).read_text(encoding="utf-8")
        for module in ("rtk_btusb", "rtk_btcoex"):
            self.assertIn(f"blacklist {module}", conf)
            self.assertIn(f"install {module} /bin/false", conf)


if __name__ == "__main__":
    unittest.main()
