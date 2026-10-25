#!/usr/bin/env python3
"""Exercise the core mesh Kconfig gate and installed NM ownership policy."""
from pathlib import Path
import configparser
import fnmatch
import textwrap
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / 'conf/distro/include/mesh-local.inc'
KERNEL = ROOT / 'recipes-kernel/linux/mesh-local.inc'
FRAGMENT = ROOT / 'recipes-kernel/linux/mesh-local/mesh-local.cfg'


def contract(name):
    text = CONTRACT.read_text()
    return re.search(r'^' + name + r' = "(.*?)"', text, re.M | re.S)[1].replace('\\', '').split()


class MeshLocalContractTest(unittest.TestCase):
    def run_gate(self, values, empty=None, missing=False):
        builtins = contract('WENDYOS_MESH_LOCAL_BUILTIN')
        modules = contract('WENDYOS_MESH_LOCAL_MODULES')
        body = re.search(r'^wendyos_check_mesh_local\(\) \{\n(.*?)^\}',
                         KERNEL.read_text(), re.M | re.S)[1]
        with tempfile.TemporaryDirectory() as tmp:
            if not missing:
                (Path(tmp) / '.config').write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
            replacements = {'B': tmp, 'MACHINE': 'test-machine',
                            'WENDYOS_MESH_LOCAL_BUILTIN': ' '.join(builtins),
                            'WENDYOS_MESH_LOCAL_MODULES': ' '.join(modules)}
            if empty:
                replacements[empty] = ''
            for name, value in replacements.items():
                body = body.replace('${' + name + '}', value)
            return subprocess.run(['sh', '-eu'], input='bbfatal() { echo "$*" >&2; exit 1; }\n' + body,
                                  text=True, capture_output=True)

    def all_values(self):
        symbols = contract('WENDYOS_MESH_LOCAL_BUILTIN')
        symbols += [v.split(':')[0] for v in contract('WENDYOS_MESH_LOCAL_MODULES')]
        return dict.fromkeys(symbols, 'y')

    def test_resolved_config(self):
        self.assertEqual(self.run_gate(self.all_values()).returncode, 0)
        values = self.all_values()
        for entry in contract('WENDYOS_MESH_LOCAL_MODULES'):
            values[entry.split(':')[0]] = 'm'
        self.assertEqual(self.run_gate(values).returncode, 0)

    def test_each_missing_feature_is_fatal(self):
        for symbol in self.all_values():
            for invalid in ('n', 'missing'):
                with self.subTest(symbol=symbol, invalid=invalid):
                    values = self.all_values()
                    if invalid == 'missing':
                        values.pop(symbol)
                    else:
                        values[symbol] = invalid
                    result = self.run_gate(values)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(symbol, result.stderr)

    def test_policy_routing_cannot_be_modular(self):
        for symbol in contract('WENDYOS_MESH_LOCAL_BUILTIN'):
            values = self.all_values()
            values[symbol] = 'm'
            self.assertNotEqual(self.run_gate(values).returncode, 0)

    def test_dummy_driver_is_required_but_stays_modular(self):
        self.assertIn('CONFIG_DUMMY:dummy', contract('WENDYOS_MESH_LOCAL_MODULES'))
        self.assertIn('CONFIG_DUMMY=m', FRAGMENT.read_text().splitlines())

    def test_missing_config_or_empty_contract_is_fatal(self):
        self.assertNotEqual(self.run_gate({}, missing=True).returncode, 0)
        for name in ('WENDYOS_MESH_LOCAL_BUILTIN', 'WENDYOS_MESH_LOCAL_MODULES'):
            self.assertNotEqual(self.run_gate(self.all_values(), empty=name).returncode, 0)

    def test_fragment_covers_contract_and_all_active_bsp_recipes_require_it(self):
        values = dict(line.split('=', 1) for line in FRAGMENT.read_text().splitlines()
                      if line.startswith('CONFIG_'))
        self.assertEqual(self.run_gate(values).returncode, 0)
        for layer, recipe in [('meta-tegra-extensions-jp7', 'linux-noble-nvidia-tegra'),
                              ('meta-rpi-extensions', 'linux-raspberrypi'),
                              ('meta-qcom-extensions', 'linux-qcom-next'),
                              ('meta-x86-extensions', 'linux-yocto'),
                              ('meta-vm-extensions', 'linux-yocto'),
                              ('meta-qemu-extensions', 'linux-yocto')]:
            text = (ROOT / layer / 'recipes-kernel/linux' / (recipe + '_%.bbappend')).read_text()
            self.assertIn('require recipes-kernel/linux/mesh-local.inc', text)

    def test_module_package_names_match_kernel_package_normalization(self):
        recipe = (ROOT / 'recipes-core/packagegroups/packagegroup-wendyos-kernel.bb').read_text()
        body = re.search(r'^python __anonymous\(\) \{\n(.*?)^\}', recipe, re.M | re.S)[1]

        class Data:
            def __init__(self):
                self.values = {'PN': 'packagegroup-wendyos-kernel',
                               'WENDYOS_MESH_LOCAL_MODULES': ' '.join(contract('WENDYOS_MESH_LOCAL_MODULES'))}

            def getVar(self, key):
                return self.values.get(key)

            def appendVar(self, key, value):
                self.values[key] = self.values.get(key, '') + value

        data = Data()
        exec(textwrap.dedent(body), {'d': data})
        self.assertEqual(data.values['RRECOMMENDS:packagegroup-wendyos-kernel'].split(),
                         ['kernel-module-dummy', 'kernel-module-ipv6', 'kernel-module-tun',
                          'kernel-module-xt-tproxy', 'kernel-module-nf-tproxy-ipv4'])

    def test_installed_nm_policy_owns_mesh_and_preserves_physical_interfaces(self):
        recipe = ROOT / 'recipes-connectivity/networkmanager/networkmanager_%.bbappend'
        text = recipe.read_text()
        body = re.search(r'^do_install:append\(\) \{\n(.*?)^\}', text, re.M | re.S)[1]
        with tempfile.TemporaryDirectory() as tmp:
            substitutions = {'D': tmp, 'UNPACKDIR': str(recipe.parent / 'files'),
                             'sysconfdir': '/etc', 'nonarch_libdir': '/usr/lib',
                             '@usb_net_nm_method(d)': 'link-local'}
            for key, value in substitutions.items():
                body = body.replace('${' + key + '}', value)
            subprocess.run(['sh', '-eu'], input=body, text=True, check=True)
            policy = Path(tmp) / 'etc/NetworkManager/conf.d/50-wendy-local-mesh.conf'
            config = configparser.ConfigParser()
            config.read(policy)
            patterns = config['keyfile']['unmanaged-devices'].split(';')

            def unmanaged(name):
                for selector in patterns:
                    pattern = selector.removeprefix('interface-name:')
                    if (pattern[1:] == name if pattern.startswith('=') else fnmatch.fnmatchcase(name, pattern)):
                        return True
                return False

            for name in ('wlmesh0', 'wlmp1', 'wlmpab', 'wlmi1', 'wlmi65534', 'wnanndi0'):
                self.assertTrue(unmanaged(name), name)
            for name in ('eth0', 'enp1s0', 'wlan0', 'usb0'):
                self.assertFalse(unmanaged(name), name)
            self.assertIn('file://50-wendy-local-mesh.conf', text)


if __name__ == '__main__':
    unittest.main()
