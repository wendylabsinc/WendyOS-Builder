#!/usr/bin/env python3
"""Run the UNO Q MCU helpers against stub GPIO, OpenOCD and systemd tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
LAYER = HERE.parent.parent / 'meta-arduino-extensions'
FILES = LAYER / 'recipes-bsp' / 'wendyos-mcu' / 'files'
ROUTER_UNIT = LAYER / 'recipes-connectivity' / 'arduino-router' / 'files' / 'wendyos-arduino-router.service'

STUB = '''#!/bin/sh
printf '%s' "$(basename "$0")" >> "$STUB_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$STUB_LOG"; done
printf '\\n' >> "$STUB_LOG"
name=$(basename "$0" | tr 'a-z-' 'A-Z_')
eval "out=\\${STUB_${name}_OUT:-}"
eval "rc=\\${STUB_${name}_RC:-0}"
[ -n "$out" ] && printf '%b\\n' "$out"
exit "$rc"
'''

GPIODETECT = (r'gpiochip0 [1c40000.spmi:pmic@0:gpio@c000] (10 lines)\n'
              r'gpiochip1 [500000.pinctrl] (127 lines)')


class Helpers(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bindir = self.tmp / 'bin'
        bindir.mkdir()
        for tool in ('gpiodetect', 'gpioset', 'gpioinfo', 'openocd', 'systemctl'):
            path = bindir / tool
            path.write_text(STUB)
            path.chmod(0o755)
        self.log = self.tmp / 'calls.log'
        self.log.touch()
        self.loader = self.tmp / 'loader.elf'
        self.loader.write_bytes(b'\x7fELF')
        self.sketch = self.tmp / 'sketch.bin'
        self.sketch.write_bytes(b'\0' * 16)
        self.env = {
            'PATH': f'{bindir}:/usr/bin:/bin',
            'STUB_LOG': str(self.log),
            'STUB_GPIODETECT_OUT': GPIODETECT,
            'MCU_SHARE_DIR': str(FILES),
            'MCU_GPIO': str(FILES / 'mcu-gpio'),
        }

    def run_tool(self, name, *args, **env):
        return subprocess.run(['sh', str(FILES / name), *args], capture_output=True, text=True,
                              env={**self.env, **env}, timeout=30)

    def flash(self, **env):
        return self.run_tool('mcu-flash', 'zephyr-1', str(self.loader), str(self.sketch), **env)

    def calls(self):
        return self.log.read_text().splitlines()

    def status(self, result):
        last = result.stdout.strip().splitlines()[-1]
        self.assertTrue(last.startswith('wendy-mcu-status '), result.stdout)
        return json.loads(last[len('wendy-mcu-status '):])

    def test_layouts_lists_zephyr1(self):
        result = self.run_tool('mcu-flash', '--layouts')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         'zephyr-1 loader=0x08000000-0x080d0000 sketch=0x08100000-0x081c0000\n')

    def test_unknown_layout_exit_2(self):
        result = self.run_tool('mcu-flash', 'zephyr-9', str(self.loader), str(self.sketch))
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown layout zephyr-9', result.stdout + result.stderr)
        self.assertFalse([c for c in self.calls() if c.startswith('openocd')])

    def test_missing_file_exit_2(self):
        result = self.run_tool('mcu-flash', 'zephyr-1', str(self.tmp / 'nope.elf'), str(self.sketch))
        self.assertEqual(result.returncode, 2)
        self.assertIn('nope.elf', result.stdout + result.stderr)
        self.assertFalse([c for c in self.calls() if c.startswith('openocd')])

    def test_gpio_resolves_chip_by_label(self):
        result = self.run_tool('mcu-gpio', '70=1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('gpioset -c gpiochip1 -t0 70=1', self.calls())

    def test_gpio_without_tlmm_fails(self):
        result = self.run_tool('mcu-gpio', '70=1', STUB_GPIODETECT_OUT='gpiochip0 [other] (8 lines)')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('500000.pinctrl', result.stderr)
        self.assertFalse([c for c in self.calls() if c.startswith('gpioset')])

    def test_boot0_low_before_openocd(self):
        result = self.flash()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        boot0 = calls.index('gpioset -c gpiochip1 -t0 37=0')
        first_openocd = next(i for i, c in enumerate(calls) if c.startswith('openocd'))
        self.assertLess(boot0, first_openocd)

    def test_openocd_args(self):
        self.flash()
        call = next(c for c in self.calls() if c.startswith('openocd'))
        for part in ('set mcu_chip 1', f'set filename0 {{{self.loader}}}',
                     f'set filename1 {{{self.sketch}}}', 'set sketch_addr 0x08100000',
                     'openocd_gpiod.cfg', 'flash-zephyr-1.cfg'):
            self.assertIn(part, call)

    def test_markers_set_written_flags(self):
        result = self.flash(STUB_OPENOCD_OUT='wendy-mcu: sketch written')
        status = self.status(result)
        self.assertTrue(status['ok'])
        self.assertTrue(status['sketch_written'])
        self.assertFalse(status['loader_written'])
        self.assertTrue(status['router_active'])

    def test_router_inactive_reported(self):
        result = self.flash(STUB_SYSTEMCTL_RC='3')
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.status(result)['router_active'])

    def test_openocd_failure_exit_4(self):
        result = self.flash(STUB_OPENOCD_RC='1', STUB_OPENOCD_OUT='Error: init mode failed')
        self.assertEqual(result.returncode, 4)
        status = self.status(result)
        self.assertFalse(status['ok'])
        self.assertTrue(status['error'])

    def test_gpio_busy_exit_3_names_consumer(self):
        result = self.flash(STUB_GPIOSET_RC='1',
                            STUB_GPIOSET_OUT='gpioset: unable to request lines: Device or resource busy',
                            STUB_GPIOINFO_OUT='gpiochip1 37\\t"unnamed"\\toutput consumer="flasher"')
        self.assertEqual(result.returncode, 3)
        self.assertIn('flasher', result.stdout + result.stderr)
        self.assertFalse([c for c in self.calls() if c.startswith('openocd')])

    def test_swd_line_busy_names_consumer(self):
        result = self.flash(STUB_GPIOINFO_OUT='gpiochip1 38\\t"unnamed"\\toutput consumer="test-holder"')
        self.assertEqual(result.returncode, 3)
        self.assertIn('test-holder', self.status(result)['error'])
        self.assertIn('gpioinfo -c gpiochip1 25 26 38', self.calls())
        self.assertFalse([c for c in self.calls() if c.startswith('openocd')])

    def test_verify_failure_after_write_exit_4(self):
        result = self.flash(STUB_OPENOCD_RC='1',
                            STUB_OPENOCD_OUT='wendy-mcu: sketch written\\nwendy-mcu: sketch verify failed')
        self.assertEqual(result.returncode, 4)
        status = self.status(result)
        self.assertFalse(status['ok'])
        self.assertIn('did not verify', status['error'])

    def openocd_calls(self):
        return [c for c in self.calls() if c.startswith('openocd')]

    def test_failed_flash_restarts_the_mcu(self):
        result = self.flash(STUB_OPENOCD_RC='1', STUB_OPENOCD_OUT='Error: write failed')
        self.assertEqual(result.returncode, 4)
        calls = self.openocd_calls()
        self.assertEqual(len(calls), 2, calls)
        self.assertIn('flash-zephyr-1.cfg', calls[0])
        self.assertIn('resume-zephyr-1.cfg', calls[1])
        self.assertNotIn('flash-zephyr-1.cfg', calls[1])

    def test_good_flash_runs_openocd_once(self):
        self.assertEqual(self.flash().returncode, 0)
        self.assertEqual(len(self.openocd_calls()), 1)

    def test_resume_mode_only_restarts(self):
        result = self.run_tool('mcu-flash', '--resume', 'zephyr-1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.status(result)['ok'])
        calls = self.openocd_calls()
        self.assertEqual(len(calls), 1)
        self.assertIn('resume-zephyr-1.cfg', calls[0])
        self.assertIn('gpioset -c gpiochip1 -t0 37=0', self.calls())

    def test_flash_recipe_ends_with_the_restart(self):
        cfg = (FILES / 'flash-zephyr-1.cfg').read_text()
        self.assertTrue(cfg.rstrip().endswith('source [find resume-zephyr-1.cfg]'))
        resume = (FILES / 'resume-zephyr-1.cfg').read_text()
        self.assertLess(resume.index('reset halt'), resume.index('resume\n'))
        self.assertTrue(resume.rstrip().endswith('shutdown'))

    def test_flash_recipe_verifies_after_each_write(self):
        cfg = (FILES / 'flash-zephyr-1.cfg').read_text()
        for image in ('loader', 'sketch'):
            written = cfg.index(f'echo "wendy-mcu: {image} written"')
            failed = cfg.index(f'echo "wendy-mcu: {image} verify failed"')
            self.assertLess(written, failed)
        self.assertEqual(cfg.count('shutdown error'), 2)

    def test_router_group_has_static_gid(self):
        recipe = (LAYER / 'recipes-connectivity' / 'arduino-router' / 'arduino-router_0.11.0.bb').read_text()
        self.assertIn('GROUPADD_PARAM:${PN} = "-r -g 880 arduino-router"', recipe)

    def test_router_unit_has_no_tcp_listener(self):
        unit = ROUTER_UNIT.read_text()
        exec_start = next(l for l in unit.splitlines() if l.startswith('ExecStart=/'))
        self.assertNotIn('--listen-port', exec_start)
        self.assertIn('--unix-port /run/arduino-router/router.sock', exec_start)
        self.assertIn('ExecStartPre=-/usr/libexec/wendyos/mcu-gpio 37=0', unit)
        self.assertIn('--after-ready "/usr/libexec/wendyos/mcu-gpio 70=1"', exec_start)


if __name__ == '__main__':
    unittest.main(verbosity=2)
