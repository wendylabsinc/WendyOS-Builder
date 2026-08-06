from __future__ import annotations

import tempfile
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import check_game_controller_support as checker  # noqa: E402


class GameControllerValidationTests(unittest.TestCase):
    def test_built_in_symbols_need_no_module_packages(self):
        config = {symbol: "y" for symbol in checker.MODULE_PACKAGES}
        self.assertEqual(checker.validate(config, set()), [])

    def test_modular_symbols_require_versioned_or_virtual_package(self):
        config = {symbol: "m" for symbol in checker.MODULE_PACKAGES}
        exact = set(checker.MODULE_PACKAGES.values())
        self.assertEqual(checker.validate(config, exact), [])

        versioned = {f"{package}-6.8.12-wendy" for package in checker.MODULE_PACKAGES.values()}
        self.assertEqual(checker.validate(config, versioned), [])

    def test_missing_symbol_and_module_are_reported(self):
        config = {symbol: "y" for symbol in checker.MODULE_PACKAGES}
        config.pop("CONFIG_INPUT_EVDEV")
        config["CONFIG_JOYSTICK_XPAD"] = "m"
        errors = checker.validate(config, set())
        self.assertTrue(any("CONFIG_INPUT_EVDEV is not enabled" in error for error in errors))
        self.assertTrue(any("kernel-module-xpad" in error for error in errors))

    def test_cli_parses_real_file_shapes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / ".config"
            manifest = root / "wendyos-image.manifest"
            config.write_text(
                "\n".join(f"{symbol}=y" for symbol in checker.MODULE_PACKAGES) + "\n",
                encoding="utf-8",
            )
            manifest.write_text("base-files aarch64 1.0\n", encoding="utf-8")
            self.assertEqual(checker.main(["--config", str(config), "--manifest", str(manifest)]), 0)


class GameControllerLayerWiringTests(unittest.TestCase):
    def test_every_shipping_kernel_includes_shared_contract(self):
        recipes = [
            "meta-tegra-extensions-jp6/recipes-kernel/linux/linux-jammy-nvidia-tegra_%.bbappend",
            "meta-tegra-extensions-jp7/recipes-kernel/linux/linux-noble-nvidia-tegra_%.bbappend",
            "meta-rpi-extensions/recipes-kernel/linux/linux-raspberrypi_%.bbappend",
            "meta-x86-extensions/recipes-kernel/linux/linux-yocto_%.bbappend",
        ]
        include = "require recipes-kernel/linux/wendy-game-controller.inc"
        for relative in recipes:
            with self.subTest(recipe=relative):
                self.assertIn(include, (REPO_ROOT / relative).read_text(encoding="utf-8"))

    def test_fragment_and_validator_symbol_sets_match(self):
        fragment = (REPO_ROOT / "recipes-kernel/linux/files/game-controller.cfg").read_text(encoding="utf-8")
        fragment_symbols = {
            line.split("=", 1)[0]
            for line in fragment.splitlines()
            if line.startswith("CONFIG_") and line.split("=", 1)[1] in {"y", "m"}
        }
        self.assertTrue(set(checker.MODULE_PACKAGES).issubset(fragment_symbols))

    def test_qemu_is_excluded_from_kernel_and_image_module_contract(self):
        x86_append = (
            REPO_ROOT / "meta-x86-extensions/recipes-kernel/linux/linux-yocto_%.bbappend"
        ).read_text(encoding="utf-8")
        packagegroup = (
            REPO_ROOT / "recipes-core/packagegroups/packagegroup-wendyos-kernel.bb"
        ).read_text(encoding="utf-8")
        self.assertIn('WENDYOS_GAME_CONTROLLER_ENABLE = "0"', x86_append)
        self.assertIn('WENDYOS_GAME_CONTROLLER_ENABLE:x86-wendyos = "1"', x86_append)
        self.assertIn('WENDYOS_GAME_CONTROLLER_ENABLE:qemuall = "0"', packagegroup)


if __name__ == "__main__":
    unittest.main()
