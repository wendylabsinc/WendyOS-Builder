#!/usr/bin/env python3
"""Run the real identity installer and boot repair code in a temporary tree."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'recipes-core/wendyos-identity/wendyos-identity_1.0.bb'
SETUP = ROOT / 'recipes-core/wendyos-etc-binds/files/setup-etc-binds.sh'
IDENTITY = 'BOARD=arduino-uno-q\nMACHINE=arduino-uno-q-wendyos\nSTORAGE=emmc\n'


class DeviceTypeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'usr/lib/wendyos/device-type'
        self.target = self.root / 'data/etc/wendyos/device-type'
        self.source.parent.mkdir(parents=True)
        self.target.parent.mkdir(parents=True)
        self.source.write_text(IDENTITY)

    def repair(self, overrides=''):
        setup = SETUP.read_text()
        # Execute the shipped functions and the entire pre-bind identity phase.
        # Exclude mount operations; all filesystem paths point into the fixture.
        functions = setup.split('# Verify /data is mounted', 1)[0]
        phase = setup.split('# PHASE 1:', 1)[1].split(
            '# Bind-mount entire /etc/wendyos/ directory', 1)[0]
        phase = phase.split('\n', 1)[1]
        script = functions + '\nlogger() { :; }\nsync() { :; }\n' + overrides
        script += '\nDATA_ETC="$1/data/etc"\n' + phase.replace(
            '/usr/lib/wendyos/device-type', '"$1/usr/lib/wendyos/device-type"')
        result = subprocess.run(['bash', '-c', script, 'test', str(self.root)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_missing_and_invalid_metadata_recovered(self):
        cases = [None, '', '\n', 'BOARD=\n', 'MACHINE=arduino-uno-q-wendyos\n',
                 'arduino-uno-q\n', 'BOARD=arduino uno q\n',
                 'BOARD=arduino-uno-q\nBOARD=\n']
        for content in cases:
            with self.subTest(content=content):
                if self.target.exists():
                    self.target.unlink()
                if content is not None:
                    self.target.write_text(content)
                self.repair()
                self.assertEqual(self.target.read_text(), IDENTITY)
                self.assertEqual(self.target.stat().st_mode & 0o777, 0o644)
                self.assertEqual(list(self.target.parent.glob('device-type.*')), [])

    def test_valid_metadata_preserved_without_rewrite(self):
        # An older valid board/storage identity must not be silently changed.
        content = 'BOARD=jetson-orin-nano\nMACHINE=older-machine\nSTORAGE=nvme'
        self.target.write_text(content)
        self.target.chmod(0o640)
        before = self.target.stat()
        self.repair()
        self.assertEqual(self.target.read_text(), content)
        self.assertEqual(self.target.stat().st_ino, before.st_ino)
        self.assertEqual(self.target.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.target.stat().st_mode, before.st_mode)

    def test_repair_uses_unshadowed_copy_and_preserves_other_identity(self):
        # Model an already-bound /etc/wendyos: it exposes the same empty file.
        etc = self.root / 'etc'
        etc.mkdir()
        (etc / 'wendyos').symlink_to(self.target.parent, target_is_directory=True)
        self.target.write_text('')
        for name in ('device-uuid', 'device-name'):
            (self.target.parent / name).write_text(name + '-original')
        self.repair()
        self.assertEqual((etc / 'wendyos/device-type').read_text(), IDENTITY)
        for name in ('device-uuid', 'device-name'):
            self.assertEqual((self.target.parent / name).read_text(), name + '-original')
        self.assertEqual(self.source.read_text(), IDENTITY)
        before = self.target.stat()
        self.repair()
        self.assertEqual(self.target.stat().st_ino, before.st_ino)

    def test_bad_source_does_not_break_configuration_mount_setup(self):
        for content in (None, '', 'BOARD=\n', 'MACHINE=only\n'):
            with self.subTest(content=content):
                if self.source.exists():
                    self.source.unlink()
                if content is not None:
                    self.source.write_text(content)
                self.target.write_text('original invalid metadata')
                result = self.repair()
                self.assertIn('continuing with configuration mounts', result.stderr)
                self.assertEqual(self.target.read_text(), 'original invalid metadata')

    def test_partial_copy_and_failed_rename_leave_target_untouched(self):
        failures = [
            'cp() { printf "BOARD=partial" > "$2"; return 1; }',
            'mv() { return 1; }',
        ]
        for override in failures:
            with self.subTest(override=override):
                self.target.write_text('')
                before = self.target.stat()
                result = self.repair(override)
                self.assertIn('Failed to restore device type', result.stderr)
                self.assertEqual(self.target.read_text(), '')
                self.assertEqual(self.target.stat().st_ino, before.st_ino)
                self.assertEqual(list(self.target.parent.glob('device-type.*')), [])

    def test_persistent_metadata_is_not_executed(self):
        sentinel = self.root / 'executed'
        self.target.write_text(f'BOARD=$(touch {sentinel})\n')
        self.repair()
        self.assertFalse(sentinel.exists())
        self.assertEqual(self.target.read_text(), IDENTITY)

    def test_recipe_installs_and_packages_both_copies(self):
        recipe = RECIPE.read_text()
        body = re.search(r'^do_install:append\(\) \{\n(.*?)^\}', recipe, re.M | re.S)[1]
        for storage in ('', 'emmc', 'nvme'):
            with self.subTest(storage=storage):
                values = {'D': str(self.root / 'image'), 'sysconfdir': '/etc',
                          'nonarch_libdir': '/usr/lib', 'STORAGE': storage,
                          'WENDYOS_BOARD_ID': 'arduino-uno-q',
                          'MACHINE': 'arduino-uno-q-wendyos'}
                script = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}',
                                lambda m: values[m[1]], body)
                subprocess.run(['sh', '-eu'], input=script, text=True, check=True)
                expected = 'BOARD=arduino-uno-q\nMACHINE=arduino-uno-q-wendyos\n'
                if storage:
                    expected += f'STORAGE={storage}\n'
                for directory, variable in (('etc', 'sysconfdir'), ('usr/lib', 'nonarch_libdir')):
                    path = self.root / 'image' / directory / 'wendyos/device-type'
                    self.assertEqual(path.read_text(), expected)
                    self.assertEqual(path.stat().st_mode & 0o777, 0o644)
                    self.assertIn(f'FILES:${{PN}} += "${{{variable}}}/wendyos/device-type"', recipe)


if __name__ == '__main__':
    unittest.main()
