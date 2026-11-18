#!/usr/bin/env python3
"""Hold the Qualcomm USB peripheral driver list, kernel fragment and image together."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / 'conf/distro/include/qcom-distro.inc'
KERNEL = ROOT / 'meta-qcom-extensions/recipes-kernel/linux/linux-qcom-next_%.bbappend'
FRAGMENT = KERNEL.parent / 'linux-qcom-next/usb-peripherals.cfg'
IMAGE = ROOT / 'conf/distro/include/qcom-image.inc'
NAME = 'WENDYOS_QCOM_USB_PERIPHERAL_MODULES'
BOARD_PACKAGEGROUPS = sorted(path for layer in ('meta-qcom-extensions', 'meta-arduino-extensions')
                             for path in (ROOT / layer / 'recipes-core/packagegroups').glob('*.bb'))

def contract():
    match = re.search(r'^' + NAME + r' = "(.*?)"', CONTRACT.read_text(), re.M | re.S)
    if not match:
        raise AssertionError(f'{NAME} is not defined in {CONTRACT.relative_to(ROOT)}')
    return dict(entry.split(':', 1) for entry in match[1].replace('\\', '').split())


class QcomUsbPeripheralsTest(unittest.TestCase):
    def run_gate(self, values, modules=None, missing=False):
        body = re.search(r'^wendyos_check_usb_peripherals\(\) \{\n(.*?)^\}',
                         KERNEL.read_text(), re.M | re.S)
        self.assertIsNotNone(body, 'the kernel bbappend has no wendyos_check_usb_peripherals gate')
        entries = contract() if modules is None else modules
        with tempfile.TemporaryDirectory() as tmp:
            if not missing:
                (Path(tmp) / '.config').write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
            # ${B}, ${MACHINE} and the list are valid shell expansions as written.
            env = {'PATH': os.environ['PATH'], 'B': tmp, 'MACHINE': 'test-machine',
                   NAME: ' '.join(f'{k}:{v}' for k, v in entries.items())}
            return subprocess.run(['sh', '-eu'], input='bbfatal() { echo "$*" >&2; exit 1; }\n' + body[1],
                                  text=True, capture_output=True, env=env)

    def test_gate_accepts_modular_drivers(self):
        result = self.run_gate(dict.fromkeys(contract(), 'm'))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_gate_rejects_each_driver_that_emits_no_package(self):
        for symbol in contract():
            for value in ('y', 'n', None):
                with self.subTest(symbol=symbol, value=value):
                    values = dict.fromkeys(contract(), 'm')
                    if value is None:
                        del values[symbol]
                    else:
                        values[symbol] = value
                    result = self.run_gate(values)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(symbol, result.stderr)

    def test_gate_rejects_an_empty_list_and_a_missing_config(self):
        for result, reason in ((self.run_gate({}, modules={}), 'driver list is empty'),
                               (self.run_gate({}, missing=True), 'no resolved kernel config')):
            with self.subTest(reason=reason):
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason, result.stderr)

    def test_fragment_requests_each_driver_as_a_module(self):
        requested = dict(line.split('=', 1) for line in FRAGMENT.read_text().splitlines()
                         if line.startswith('CONFIG_'))
        for symbol in contract():
            with self.subTest(symbol=symbol):
                self.assertEqual(requested.get(symbol), 'm')

    def test_every_qcom_kernel_gets_the_fragment_and_the_gate(self):
        text = KERNEL.read_text()
        self.assertRegex(text, r'SRC_URI:append:qcom-wendyos = "[^"]*file://usb-peripherals\.cfg')
        blocks = re.findall(r"if 'qcom-wendyos' in [^\n]*\n((?:        [^\n]*\n)+)", text)
        self.assertTrue(any("'postfuncs', ' wendyos_check_usb_peripherals'" in block for block in blocks),
                        'no qcom-wendyos block registers the gate on do_configure')

    def test_image_installs_the_package_of_each_driver(self):
        entries = contract()
        for package in entries.values():
            self.assertTrue(package.startswith('kernel-module-'), package)
        # Unscoped and space-led: every qcom image gets the whole list as separate words.
        installs = re.findall(r'^IMAGE_INSTALL:append = " \$\{@(.*' + NAME + r'.*)\}"$',
                              IMAGE.read_text(), re.M)
        self.assertEqual(len(installs), 1, 'qcom-image.inc must install the listed packages once')
        value = ' '.join(f'{symbol}:{package}' for symbol, package in entries.items())
        data = types.SimpleNamespace(getVar=lambda key: {NAME: value}[key])
        self.assertEqual(eval(installs[0], {'__builtins__': {}, 'd': data}).split(), list(entries.values()))

    def test_no_board_packagegroup_repeats_a_listed_driver(self):
        self.assertTrue(BOARD_PACKAGEGROUPS, 'no board packagegroup found')
        for path in BOARD_PACKAGEGROUPS:
            code = '\n'.join(line for line in path.read_text().splitlines()
                             if not line.lstrip().startswith('#'))
            for package in contract().values():
                with self.subTest(packagegroup=path.name, package=package):
                    self.assertNotRegex(code, r'(?<![\w-])' + re.escape(package) + r'(?![\w-])')


if __name__ == '__main__':
    unittest.main()
