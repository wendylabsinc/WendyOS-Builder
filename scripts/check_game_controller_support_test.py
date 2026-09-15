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

CONTRACT = checker.load_contract(checker.DEFAULT_CONTRACT)
ALL_SYMBOLS = CONTRACT.builtin | set(CONTRACT.modules)
FRAGMENT = REPO_ROOT / "recipes-kernel/linux/game-controller/game-controller.cfg"
GATED_REQUIRE = "recipes-kernel/linux/game-controller.inc"


def kernel_bbappends() -> list[Path]:
    """Every kernel bbappend in the tree. A layer with no kernel bbappend is invisible here."""

    return sorted(REPO_ROOT.glob("meta-*/recipes-kernel/linux/linux-*.bbappend"))


class ContractTests(unittest.TestCase):
    def test_contract_is_read_from_the_bitbake_definition(self):
        self.assertTrue(CONTRACT.builtin, "no built-in symbols parsed")
        self.assertTrue(CONTRACT.modules, "no modular symbols parsed")
        for symbol, package in CONTRACT.modules.items():
            with self.subTest(symbol=symbol):
                self.assertTrue(package.startswith("kernel-module-"))

    def test_a_symbol_is_either_built_in_or_modular_never_both(self):
        self.assertEqual(CONTRACT.builtin & set(CONTRACT.modules), set())

    def test_an_empty_contract_is_refused_rather_than_passing_vacuously(self):
        """A contract that parses to nothing would let every board through unchecked."""

        with tempfile.TemporaryDirectory() as directory:
            empty = Path(directory) / "game-controller.inc"
            empty.write_text(
                'WENDYOS_GAME_CONTROLLER_BUILTIN = ""\n'
                'WENDYOS_GAME_CONTROLLER_MODULES = ""\n',
                encoding="utf-8",
            )
            with self.assertRaises(ValueError):
                checker.load_contract(empty)

    def test_emptying_one_list_is_refused(self):
        self._assert_rejected('WENDYOS_GAME_CONTROLLER_BUILTIN = "CONFIG_HID"\n'
                              'WENDYOS_GAME_CONTROLLER_MODULES = ""\n')

    def test_a_module_entry_without_a_package_is_refused(self):
        self._assert_rejected('WENDYOS_GAME_CONTROLLER_BUILTIN = "CONFIG_HID"\n'
                              'WENDYOS_GAME_CONTROLLER_MODULES = "CONFIG_UHID"\n')

    def test_an_assignment_the_parser_cannot_read_is_refused(self):
        """An :append is applied by BitBake but invisible here, so the list would be stale."""

        self._assert_rejected('WENDYOS_GAME_CONTROLLER_BUILTIN = "CONFIG_HID"\n'
                              'WENDYOS_GAME_CONTROLLER_MODULES = "CONFIG_UHID:kernel-module-uhid"\n'
                              'WENDYOS_GAME_CONTROLLER_MODULES:append = " CONFIG_X:kernel-module-x"\n')

    def _assert_rejected(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "game-controller.inc"
            path.write_text(text, encoding="utf-8")
            with self.assertRaises(ValueError):
                checker.load_contract(path)

    def test_fragment_requests_every_contract_symbol_with_the_contracted_value(self):
        requested = dict(
            line.split("=", 1)
            for line in FRAGMENT.read_text(encoding="utf-8").splitlines()
            if line.startswith("CONFIG_") and "=" in line
        )
        expected = {symbol: "y" for symbol in CONTRACT.builtin}
        expected.update({symbol: "m" for symbol in CONTRACT.modules})
        self.assertEqual({symbol: requested.get(symbol) for symbol in expected}, expected)


class ValidationTests(unittest.TestCase):
    def test_everything_built_in_needs_no_module_packages(self):
        config = {symbol: "y" for symbol in ALL_SYMBOLS}
        self.assertEqual(checker.validate(config, set(), CONTRACT), [])

    def test_modular_symbols_accept_exact_or_versioned_package(self):
        config = {symbol: "y" for symbol in CONTRACT.builtin}
        config.update({symbol: "m" for symbol in CONTRACT.modules})
        self.assertEqual(checker.validate(config, set(CONTRACT.modules.values()), CONTRACT), [])

        versioned = {f"{p}-6.12.87-v8-16k" for p in CONTRACT.modules.values()}
        self.assertEqual(checker.validate(config, versioned, CONTRACT), [])

    def test_a_different_driver_does_not_satisfy_a_shorter_symbol(self):
        """kernel-module-bluetooth-6lowpan really ships, and is not a versioned bluetooth."""

        contract = checker.Contract(
            builtin=frozenset(), modules={"CONFIG_BT": "kernel-module-bluetooth"}
        )
        for sibling in ("kernel-module-bluetooth-6lowpan-6.18.33-v8-16k",
                        "kernel-module-hid-generic-6.12.87-v8-16k"):
            with self.subTest(sibling=sibling):
                errors = checker.validate({"CONFIG_BT": "m"}, {sibling}, contract)
                self.assertEqual(len(errors), 1)
                self.assertIn("kernel-module-bluetooth is absent", errors[0])

    def test_a_built_in_symbol_demoted_to_a_module_is_reported(self):
        """A vendor kernel silently downgrading =y to =m is the likeliest real regression."""

        symbol = sorted(CONTRACT.builtin)[0]
        config = {s: "y" for s in ALL_SYMBOLS}
        config[symbol] = "m"
        errors = checker.validate(config, set(CONTRACT.modules.values()), CONTRACT)
        self.assertEqual(len(errors), 1)
        self.assertIn(f"{symbol} must be built in", errors[0])

    def test_disabled_symbol_and_missing_module_are_both_reported(self):
        config = {symbol: "y" for symbol in ALL_SYMBOLS}
        config.pop("CONFIG_INPUT_EVDEV")
        config["CONFIG_JOYSTICK_XPAD"] = "m"
        errors = checker.validate(config, set(), CONTRACT)
        self.assertTrue(any("CONFIG_INPUT_EVDEV must be built in" in e for e in errors))
        self.assertTrue(any("kernel-module-xpad is absent" in e for e in errors))

    def test_cli_reads_real_config_and_manifest_shapes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / ".config"
            manifest = root / "wendyos-image.manifest"
            config.write_text(
                "\n".join(f"{symbol}=y" for symbol in ALL_SYMBOLS) + "\n",
                encoding="utf-8",
            )
            manifest.write_text("base-files aarch64 1.0\n", encoding="utf-8")
            self.assertEqual(
                checker.main(["--config", str(config), "--manifest", str(manifest)]), 0
            )


class LayerWiringTests(unittest.TestCase):
    def test_every_shipping_kernel_requires_the_contract(self):
        shipping = [p for p in kernel_bbappends() if "meta-qemu-extensions" not in p.parts]
        self.assertTrue(shipping, "no shipping kernel bbappends found")
        for bbappend in shipping:
            with self.subTest(bbappend=str(bbappend.relative_to(REPO_ROOT))):
                text = bbappend.read_text(encoding="utf-8")
                self.assertIn(GATED_REQUIRE, text)
                self.assertIn("WENDYOS_GAME_CONTROLLER", text)

    def test_qemu_kernel_is_outside_the_hardware_contract(self):
        for bbappend in kernel_bbappends():
            if "meta-qemu-extensions" in bbappend.parts:
                self.assertNotIn(GATED_REQUIRE, bbappend.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
