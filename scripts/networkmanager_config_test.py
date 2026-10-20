#!/usr/bin/env python3
"""Execute the NetworkManager recipe installer and check its connection defaults."""
from configparser import ConfigParser
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'recipes-connectivity/networkmanager/networkmanager_%.bbappend'
FILES = RECIPE.parent / 'files'
DHCP_CONF = '20-ethernet-dhcp.conf'


def install_body():
    body = re.search(r'^do_install:append\(\) \{\n(.*?)^\}', RECIPE.read_text(), re.M | re.S)[1]
    return body.replace('${@usb_net_nm_method(d)}', 'link-local')


def run_install(values):
    """Run do_install:append with the given variables; map installed paths to files."""
    script = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', lambda m: values[m[1]], install_body())
    subprocess.run(['sh', '-eu'], input=script, text=True, check=True)
    root = Path(values['D'])
    return {str(p.relative_to(root)): p for p in root.rglob('*') if p.is_file()}


def install_values(dest):
    return {'D': dest, 'UNPACKDIR': str(FILES), 'sysconfdir': '/etc', 'nonarch_libdir': '/usr/lib'}


def nm_conf(path):
    conf = ConfigParser(interpolation=None)
    conf.optionxform = str
    conf.read(path)
    return conf


class NetworkManagerConfigTest(unittest.TestCase):
    def test_ethernet_dhcp_never_times_out(self):
        conf = nm_conf(FILES / DHCP_CONF)
        self.assertEqual(conf.sections(), ['connection-ethernet-dhcp'])
        self.assertEqual(dict(conf['connection-ethernet-dhcp']), {
            'match-device': 'type:ethernet,except:interface-name:usb0',
            'ipv4.dhcp-timeout': '2147483647',
        })

    def test_no_other_section_overrides_ethernet_dhcp_timeout(self):
        # A bare [connection] is always searched last, but another
        # [connection-*] section could override this timeout outside usb0.
        with tempfile.TemporaryDirectory() as tmp:
            installed = run_install(install_values(tmp))
            for path, file in installed.items():
                if not (path.startswith('etc/NetworkManager/') and path.endswith('.conf')):
                    continue
                conf = nm_conf(file)
                for section in conf.sections():
                    if (section.startswith('connection-') and section != 'connection-ethernet-dhcp'
                            and conf.has_option(section, 'ipv4.dhcp-timeout')):
                        self.assertEqual(conf.get(section, 'match-device', fallback=''),
                                         'interface-name:usb0', f'{path} [{section}]')

    def test_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            installed = run_install(install_values(tmp))
            for target, source, mode in (
                (f'etc/NetworkManager/conf.d/{DHCP_CONF}', DHCP_CONF, 0o644),
                # NetworkManager runs only root-owned dispatcher scripts that
                # group and others cannot write.
                ('usr/lib/NetworkManager/dispatcher.d/50-wendyos-dhcp-ntp', 'wendyos-dhcp-ntp.sh', 0o755),
            ):
                self.assertIn(target, installed)
                self.assertEqual(installed[target].read_bytes(), (FILES / source).read_bytes())
                self.assertEqual(installed[target].stat().st_mode & 0o777, mode)
        fetched = set(re.findall(r'file://(\S+)', RECIPE.read_text()))
        sources = set(re.findall(r'\$\{UNPACKDIR\}/(\S+)', install_body()))
        self.assertTrue(sources <= fetched, sources - fetched)


if __name__ == '__main__':
    unittest.main()
