"""Config-only kernel ABI changes must select different matching add-ons."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'recipes-kernel/linux/driver-extensions/kernel-config-identity.py'
spec = importlib.util.spec_from_file_location('kernel_config_identity', HELPER)
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)

CONFIG = '''# Linux/arm64 7.2 Kernel Configuration
CONFIG_64BIT=y
CONFIG_LOCALVERSION="-wendyos"
CONFIG_LOCALVERSION_AUTO=y
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"
CONFIG_MODVERSIONS=y
CONFIG_DUMMY=m
# CONFIG_DEBUG_INFO is not set
'''


class ConfigIdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / '.config'
        self.config.write_text(CONFIG)

    def test_config_only_changes_get_distinct_release_suffixes(self):
        original = identity.update(self.config)
        self.assertRegex(original, r'^-wendyos-cfg[0-9a-f]{16}$')
        for old, new in [('CONFIG_DUMMY=m', 'CONFIG_DUMMY=y'),
                         ('CONFIG_MODVERSIONS=y', '# CONFIG_MODVERSIONS is not set'),
                         ('# CONFIG_DEBUG_INFO is not set', 'CONFIG_DEBUG_INFO=y')]:
            with self.subTest(setting=old):
                self.config.write_text(CONFIG.replace(old, new))
                self.assertNotEqual(original, identity.update(self.config))

    def test_repeated_configure_does_not_hash_its_own_suffix_or_rewrite(self):
        original = identity.update(self.config)
        before = self.config.stat().st_mtime_ns
        self.assertEqual(original, identity.update(self.config))
        self.assertEqual(before, self.config.stat().st_mtime_ns)
        self.assertEqual(self.config.read_text().count('-cfg'), 1)

    def test_resolved_options_ignore_comments_order_and_build_directory(self):
        original = identity.update(self.config)
        elsewhere = self.root / 'another-build'
        elsewhere.mkdir()
        relocated = elsewhere / '.config'
        relocated.write_text('# different generated header\n' + '\n'.join(reversed(CONFIG.splitlines())))
        self.assertEqual(original, identity.update(relocated))

    def test_signing_key_location_is_not_a_config_identity(self):
        original = identity.update(self.config)
        self.config.write_text(CONFIG.replace('certs/signing_key.pem', '/other-build/certs/key.pem'))
        self.assertEqual(original, identity.update(self.config))
        self.assertIn('CONFIG_MODULE_SIG_KEY="/other-build/certs/key.pem"', self.config.read_text())

    def test_existing_localversion_prefix_is_preserved_and_hashed(self):
        original = identity.update(self.config)
        self.config.write_text(CONFIG.replace('-wendyos', '-vendor-board'))
        changed = identity.update(self.config)
        self.assertTrue(changed.startswith('-vendor-board-cfg'))
        self.assertNotEqual(original.split('-cfg')[1], changed.split('-cfg')[1])

    def test_invalid_or_duplicate_localversion_fails_without_modifying_config(self):
        for text in [CONFIG.replace('CONFIG_LOCALVERSION="-wendyos"\n', ''),
                     CONFIG + 'CONFIG_LOCALVERSION="-other"\n',
                     CONFIG.replace('-wendyos', '../outside')]:
            with self.subTest(config=text):
                self.config.write_text(text)
                with self.assertRaises((KeyError, ValueError)):
                    identity.update(self.config)
                self.assertEqual(self.config.read_text(), text)

    def test_real_bitbake_postfunc_updates_the_resolved_build_config(self):
        shutil.copy2(HELPER, self.root / HELPER.name)
        include = (ROOT / 'recipes-kernel/linux/driver-extensions.inc').read_text()
        body = include.split('python wendyos_set_kernel_config_identity() {\n', 1)[1].split('\n}', 1)[0]

        def fatal(message):
            raise ValueError(message)

        values = {'B': str(self.root), 'UNPACKDIR': str(self.root)}
        exec(textwrap.dedent(body), {'d': SimpleNamespace(getVar=values.get),
                                    'bb': SimpleNamespace(fatal=fatal, note=lambda message: None)})
        self.assertRegex(self.config.read_text(), r'CONFIG_LOCALVERSION="-wendyos-cfg[0-9a-f]{16}"')

    def test_cli_reports_missing_config(self):
        result = subprocess.run([sys.executable, str(HELPER), str(self.root / 'missing')],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No such file', result.stderr)
    @unittest.skipUnless(os.environ.get('WENDY_KERNEL_SETLOCALVERSION'), 'optional pinned Linux script integration')
    def test_pinned_linux_release_changes_only_when_config_changes(self):
        # Invoke the real pinned kernel script, with auto.conf in the form that
        # kbuild syncconfig produces. Source identity remains the kernel's job.
        source = self.root / 'source'
        source.mkdir()
        (source / 'Makefile').write_text('VERSION = 7\nPATCHLEVEL = 2\nSUBLEVEL = 0\n')
        subprocess.run(['git', 'init', '-q', str(source)], check=True)
        subprocess.run(['git', '-C', str(source), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                        'add', 'Makefile'], check=True)
        subprocess.run(['git', '-C', str(source), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                        'commit', '-qm', 'Pinned source fixture'], check=True)
        auto = self.root / 'include/config/auto.conf'
        auto.parent.mkdir(parents=True)

        def release(config):
            self.config.write_text(config)
            suffix = identity.update(self.config)
            # auto.conf omits quotes around string-valued settings.
            auto.write_text('CONFIG_LOCALVERSION=' + suffix + '\nCONFIG_LOCALVERSION_AUTO=y\n')
            result = subprocess.run(['sh', os.environ['WENDY_KERNEL_SETLOCALVERSION'], str(source)],
                                    cwd=self.root, env=os.environ | {'KERNELVERSION': '7.2.0', 'LOCALVERSION': ''},
                                    text=True, capture_output=True, check=True)
            return result.stdout.strip()

        first = release(CONFIG)
        self.assertRegex(first, r'^7\.2\.0-wendyos-cfg[0-9a-f]{16}-g[0-9a-f]+$')
        self.assertEqual(first, release(CONFIG))
        changed = release(CONFIG.replace('CONFIG_DUMMY=m', 'CONFIG_DUMMY=y'))
        self.assertNotEqual(first, changed)
        self.assertEqual(first.rsplit('-g', 1)[1], changed.rsplit('-g', 1)[1])
        print('Pinned Linux releases:', first, changed)


if __name__ == '__main__':
    unittest.main()
