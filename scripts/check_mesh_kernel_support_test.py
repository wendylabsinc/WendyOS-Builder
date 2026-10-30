"""Image acceptance failures that config-only checks and recommendations miss."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check_mesh_kernel_support.py')
spec = importlib.util.spec_from_file_location('mesh_kernel_check', SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class ImageAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.release = '6.18.33-v8-16k-wendy-mesh2'
        self.modules = self.root / 'usr/lib/modules' / self.release
        self.modules.mkdir(parents=True)
        self.config = {'CONFIG_IPV6_MULTIPLE_TABLES': 'y', 'CONFIG_IPV6_TUNNEL': 'm', 'CONFIG_IP6_NF_NAT': 'm'}
        self.contract = {'CONFIG_IPV6_TUNNEL': 'ip6_tunnel', 'CONFIG_IP6_NF_NAT': 'ip6table_nat'}
        self.files = {
            'kernel/net/ipv6/ip6_tunnel.ko.xz': ['kernel/net/ipv6/tunnel6.ko.xz'],
            'kernel/net/ipv6/tunnel6.ko.xz': [],
            'kernel/net/ipv6/netfilter/ip6table_nat.ko.xz': ['kernel/net/netfilter/nf_nat.ko.xz'],
            'kernel/net/netfilter/nf_nat.ko.xz': [],
        }
        self.write_modules()

    def write_modules(self):
        for name in self.files:
            p = self.modules / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b'fixture module content')
        (self.modules / 'modules.dep').write_text(''.join(f'{name}: {" ".join(deps)}\n' for name, deps in self.files.items()))

    def validate(self):
        return check.validate(self.config, self.root, self.release,
                              ['CONFIG_IPV6_MULTIPLE_TABLES'], self.contract)

    def test_packaged_compressed_modules_and_dependencies_pass(self):
        self.assertEqual(self.validate(), [])

    def test_builtin_features_need_no_module_packages(self):
        self.config = {symbol: 'y' for symbol in self.config}
        (self.modules / 'modules.dep').unlink()
        self.assertEqual(self.validate(), [])

    def test_published_pi_config_missing_nat_fails(self):
        del self.config['CONFIG_IP6_NF_NAT']
        self.assertTrue(any('CONFIG_IP6_NF_NAT is not enabled' in x for x in self.validate()))

    def test_enabled_but_uninstalled_recommendation_fails(self):
        # The package manifest can say installed while its actual file is absent.
        (self.modules / 'kernel/net/ipv6/netfilter/ip6table_nat.ko.xz').unlink()
        self.assertTrue(any('missing or invalid module file' in x for x in self.validate()))

    def test_missing_transitive_dependency_fails(self):
        (self.modules / 'kernel/net/netfilter/nf_nat.ko.xz').unlink()
        self.assertTrue(any('nf_nat.ko.xz' in x for x in self.validate()))

    def test_stale_other_kernel_does_not_satisfy_image(self):
        self.release = '6.18.33-v8-16k-wendy-mesh1'
        self.assertTrue(any('missing installed module directory' in x for x in self.validate()))

    def test_similarly_named_module_does_not_satisfy_contract(self):
        old = 'kernel/net/ipv6/netfilter/ip6table_nat.ko.xz'
        deps = self.files.pop(old)
        self.files[old.replace('ip6table_nat', 'ip6table_nat_extra')] = deps
        self.write_modules()
        self.assertTrue(any('found 0' in x for x in self.validate()))

    def test_wrong_boolean_config_fails_even_with_modules_present(self):
        self.config['CONFIG_IPV6_MULTIPLE_TABLES'] = 'm'
        self.assertTrue(any('must be built in' in x for x in self.validate()))

    def test_module_cannot_escape_rootfs_via_symlink(self):
        path = self.modules / 'kernel/net/netfilter/nf_nat.ko.xz'
        path.unlink()
        path.symlink_to(SCRIPT)
        self.assertTrue(any('missing or invalid module file' in x for x in self.validate()))

    def test_depmod_is_required_after_rootfs_construction(self):
        (self.modules / 'modules.dep').unlink()
        self.assertTrue(any('after depmod' in x for x in self.validate()))

    def test_invalid_dependency_path_fails(self):
        with (self.modules / 'modules.dep').open('a') as f:
            f.write('kernel/extra.ko: ../../foreign.ko\n')
        self.assertTrue(any('invalid modules.dep' in x for x in self.validate()))

    def test_uncompressed_and_zstd_modules_are_supported(self):
        self.files = {name.replace('.ko.xz', '.ko.zst'): [d.replace('.ko.xz', '.ko.zst') for d in deps]
                      for name, deps in self.files.items()}
        self.files['kernel/net/ipv6/tunnel6.ko'] = self.files.pop('kernel/net/ipv6/tunnel6.ko.zst')
        self.files['kernel/net/ipv6/ip6_tunnel.ko.zst'] = ['kernel/net/ipv6/tunnel6.ko']
        self.write_modules()
        self.assertEqual(self.validate(), [])

    def test_cli_refuses_empty_contract(self):
        config = self.root / '.config'
        config.write_text('CONFIG_IPV6=y\n')
        result = subprocess.run([sys.executable, str(SCRIPT), '--config', str(config),
                                 '--rootfs', str(self.root), '--kernel-release', self.release],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('empty mesh module contract', result.stderr)

    def test_cli_checks_base_image_modules_and_their_dependencies(self):
        config = self.root / '.config'
        config.write_text('CONFIG_IPV6_TUNNEL=m\n')
        args = [sys.executable, str(SCRIPT), '--config', str(config),
                '--rootfs', str(self.root), '--kernel-release', self.release,
                '--external-module', 'ip6_tunnel']
        result = subprocess.run(args, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.modules / 'kernel/net/ipv6/tunnel6.ko.xz').unlink()
        result = subprocess.run(args, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires missing or invalid module file', result.stderr)


if __name__ == '__main__':
    unittest.main()
