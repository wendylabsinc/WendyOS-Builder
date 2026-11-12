#!/usr/bin/env python3
"""Run bind setup against temporary files; emulate mounts without root access.

These tests exercise file preservation and diagnostics, not kernel bind mounts
or NetworkManager activation. No device profiles or credentials are accessed.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'recipes-core/wendyos-etc-binds/files/setup-etc-binds.sh'
CONNECTIONS = 'NetworkManager/system-connections'
PROFILE = b'''[connection]
id=Test WiFi
uuid=01b23e2b-23e6-4b08-9dbf-801959f3b0ea
type=wifi
[wifi]
ssid=Test WiFi
[wifi-security]
key-mgmt=wpa-psk
psk=test-only-password
[ipv4]
method=auto
'''


class WiFiProfilePersistenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.profiles = self.root / 'data/etc' / CONNECTIONS
        self.distro = self.root / 'usr/lib' / CONNECTIONS
        for relative in ('data', 'config', 'etc/wendyos', 'etc/wendy-agent',
                         f'etc/{CONNECTIONS}', f'data/etc/{CONNECTIONS}',
                         f'usr/lib/{CONNECTIONS}', 'bin'):
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        # Relocate fixed device paths in the real script. Keep all file
        # operations real; only mount(8), mountpoint(1) and syslog are emulated.
        script = re.sub(r'(?<![\w/])/(?:data|etc|usr/lib|config)(?=[/"\s])',
                        lambda m: str(self.root) + m[0], SCRIPT.read_text())
        self.script = self.root / 'setup.sh'
        self.script.write_text(script)
        self.env = {**os.environ, 'PATH': f'{self.root}/bin:{os.environ["PATH"]}',
                    'TEST_ROOT': str(self.root)}
        self.stub('mountpoint', '''
path = Path(sys.argv[-1])
sys.exit(0 if path.is_symlink() or path in (root / 'data', root / 'config') else 1)
''')
        self.stub('mount', '''
assert sys.argv[1] == '--bind'
source, target = map(Path, sys.argv[2:])
assert root in source.parents and root in target.parents
target.rmdir()
target.symlink_to(source, target_is_directory=True)
''')
        self.stub('logger', r'''
with (root / 'journal').open('a') as log:
    log.write(' '.join(sys.argv[1:]) + '\n')
sys.exit(1 if os.environ.get('FAIL_WARNING_LOG') and 'user.warning' in sys.argv else 0)
''')

    def stub(self, name, body):
        path = self.root / 'bin' / name
        path.write_text(f'#!{sys.executable}\nimport os, sys\nfrom pathlib import Path\n'
                        'root = Path(os.environ["TEST_ROOT"])\n' + body)
        path.chmod(0o755)

    def profile(self, name, content=PROFILE):
        path = self.profiles / name
        path.write_bytes(content)
        path.chmod(0o600)
        return path

    def snapshot(self, path):
        stat = path.stat()
        return path.read_bytes(), stat.st_mode & 0o777, stat.st_mtime_ns, stat.st_ino

    def run_setup(self):
        result = subprocess.run(['bash', str(self.script)], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('All bind mounts successfully configured', result.stdout)
        self.assertNotIn('test-only-password', result.stdout + result.stderr)
        self.assertNotIn('test-only-password', (self.root / 'journal').read_text())
        return result

    def test_empty_profile_is_reported_and_preserved_beside_working_replacement(self):
        empty = self.profile('Test WiFi.nmconnection', b'')
        working = self.profile('Test WiFi-replacement.nmconnection')
        before = {p: self.snapshot(p) for p in (empty, working)}
        for _ in range(2):
            result = self.run_setup()
            self.assertIn('Empty persistent NetworkManager profile:', result.stderr)
            self.assertIn('no saved settings or credentials', result.stderr)
            self.assertEqual({p: self.snapshot(p) for p in before}, before)
        self.assertIn('user.warning', (self.root / 'journal').read_text())

    def test_ota_distro_profile_change_preserves_user_wifi(self):
        wifi = self.profile('Test WiFi.nmconnection')
        before = self.snapshot(wifi)
        distro = self.distro / 'usb-gadget.nmconnection'
        distro.write_text('[connection]\nid=usb-gadget\ntype=ethernet\n')
        self.run_setup()
        # Simulate a new rootfs with the same persistent /data, and a stale
        # distro copy whose hash is recorded by the first boot.
        stale = self.profile(distro.name, distro.read_bytes())
        for relative in ('etc/wendyos', f'etc/{CONNECTIONS}', 'etc/wendy-agent'):
            target = self.root / relative
            target.unlink()
            target.mkdir()
        distro.write_text('[connection]\nid=usb-gadget\ntype=ethernet\n[ipv4]\nmethod=auto\n')
        result = self.run_setup()
        self.assertFalse(stale.exists())
        self.assertEqual(self.snapshot(wifi), before)
        self.assertNotIn('[WARN]', result.stderr)
        digest = (self.profiles / '.distro-hashes' / (distro.name + '.sha256')).read_text().strip()
        self.assertEqual(digest, hashlib.sha256(distro.read_bytes()).hexdigest())

    def test_user_modified_distro_profile_is_preserved(self):
        distro = self.distro / 'usb-gadget.nmconnection'
        distro.write_text('[connection]\nid=usb-gadget\ntype=ethernet\n')
        self.run_setup()
        modified = self.profile(distro.name, distro.read_bytes() + b'[ipv4]\nmethod=manual\n')
        before = self.snapshot(modified)
        self.run_setup()
        self.assertEqual(self.snapshot(modified), before)

    def test_no_profiles_or_non_profile_files_do_not_warn(self):
        self.run_setup()
        self.profile('notes', b'')
        (self.profiles / 'directory.nmconnection').mkdir()
        self.assertNotIn('[WARN]', self.run_setup().stderr)

    def test_warning_logger_failure_does_not_fail_boot(self):
        self.profile('empty.nmconnection', b'')
        self.env['FAIL_WARNING_LOG'] = '1'
        self.assertIn('[WARN]', self.run_setup().stderr)

    def test_control_characters_in_filename_cannot_forge_log_lines(self):
        self.profile('empty\nforged.nmconnection', b'')
        result = self.run_setup()
        self.assertEqual(len(result.stderr.splitlines()), 1)
        self.assertIn('\\n', result.stderr)
        self.assertNotIn('\nforged', (self.root / 'journal').read_text())


if __name__ == '__main__':
    unittest.main()
