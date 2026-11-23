#!/usr/bin/env python3
"""Check that an image with UART login off keeps no serial getty, including the
one systemd-getty-generator adds for the kernel console at every boot."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / 'recipes-core/images/wendyos-image.bb'
WANTS = 'etc/systemd/system/getty.target.wants'
GENERATOR = 'usr/lib/systemd/system-generators/systemd-getty-generator'
GENERATOR_MASK = 'etc/systemd/system-generators/systemd-getty-generator'


def uart_gate(knob):
    """The ROOTFS_POSTPROCESS_COMMAND entry the image adds for this UART login value."""
    expr = re.search(r'^ROOTFS_POSTPROCESS_COMMAND \+= "\$\{@(.*disable_uart_login.*)\}"$',
                     IMAGE.read_text(), re.M)[1]
    d = types.SimpleNamespace(getVar={'WENDYOS_ENABLE_UART_LOGIN': knob}.get)
    oe = types.SimpleNamespace(utils=types.SimpleNamespace(ifelse=lambda c, a, b: a if c else b))
    return eval(expr, {'d': d, 'oe': oe})


class UartLoginGateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # What systemd and systemd-serialgetty install before the image recipe runs.
        wants = self.root / WANTS
        wants.mkdir(parents=True)
        (wants / 'serial-getty@ttyTCU0.service').symlink_to('/usr/lib/systemd/system/serial-getty@.service')
        (wants / 'getty@tty1.service').symlink_to('/usr/lib/systemd/system/getty@.service')
        generator = self.root / GENERATOR
        generator.parent.mkdir(parents=True)
        generator.write_text('#!/bin/sh\n')

    def disable_uart_login(self):
        body = re.search(r'^disable_uart_login\(\) \{\n(.*?)^\}', IMAGE.read_text(), re.M | re.S)[1]
        for key, value in {'IMAGE_ROOTFS': str(self.root), 'sysconfdir': '/etc',
                           'systemd_unitdir': '/usr/lib/systemd'}.items():
            body = body.replace('${' + key + '}', value)
        self.assertNotIn('${', body)
        subprocess.run(['sh', '-eu'], input=body, text=True, check=True)

    def test_gate_runs_only_with_uart_login_off(self):
        self.assertEqual(uart_gate('0'), 'disable_uart_login')
        self.assertEqual(uart_gate('1'), '')

    def test_kernel_console_getty_generator_is_masked(self):
        self.disable_uart_login()
        self.assertEqual(os.readlink(self.root / GENERATOR_MASK), '/dev/null')
        self.assertEqual((self.root / GENERATOR).read_text(), '#!/bin/sh\n')

    def test_serial_getty_is_disabled_and_vt_getty_is_kept(self):
        self.disable_uart_login()
        self.assertEqual(sorted(p.name for p in (self.root / WANTS).iterdir()), ['getty@tty1.service'])
        preset = self.root / 'usr/lib/systemd/system-preset/10-wendyos-no-uart-login.preset'
        self.assertEqual(preset.read_text(), 'disable serial-getty@.service\n')


if __name__ == '__main__':
    unittest.main()
