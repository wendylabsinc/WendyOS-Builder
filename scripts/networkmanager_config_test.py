#!/usr/bin/env python3
"""Execute the NetworkManager recipe installer and check its connection defaults."""
from configparser import ConfigParser
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'recipes-connectivity/networkmanager/networkmanager_%.bbappend'
FILES = RECIPE.parent / 'files'
DISTRO_CONF = ROOT / 'conf/distro/wendyos.conf'
DHCP_CONF = '20-ethernet-dhcp.conf'
CONNECTIVITY_CONF = 'etc/NetworkManager/conf.d/30-connectivity.conf'


class Fatal(Exception):
    pass


def distro_default(name):
    return re.search(rf'^{name} \?= "(.*)"$', DISTRO_CONF.read_text(), re.M)[1]


def check_connectivity_overrides(uri, interval):
    """Run the recipe's parse-time check; raises Fatal where bitbake would stop."""
    body = re.search(r'^python \(\) \{\n(.*?)^\}', RECIPE.read_text(), re.M | re.S)[1]
    values = {'WENDYOS_NM_CONNECTIVITY_URI': uri, 'WENDYOS_NM_CONNECTIVITY_INTERVAL': interval}

    class Data:
        def getVar(self, key):
            return values.get(key)

    class Bb:
        @staticmethod
        def fatal(msg):
            raise Fatal(msg)

    exec(textwrap.dedent(body), {'d': Data(), 'bb': Bb})


def install_body():
    body = re.search(r'^do_install:append\(\) \{\n(.*?)^\}', RECIPE.read_text(), re.M | re.S)[1]
    return body.replace('${@usb_net_nm_method(d)}', 'link-local')


def run_install(values):
    """Run do_install:append with the given variables; map installed paths to files."""
    script = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', lambda m: values[m[1]], install_body())
    subprocess.run(['sh', '-eu'], input=script, text=True, check=True)
    root = Path(values['D'])
    return {str(p.relative_to(root)): p for p in root.rglob('*') if p.is_file()}


def install_values(dest, **overrides):
    values = {'D': dest, 'UNPACKDIR': str(FILES), 'sysconfdir': '/etc', 'nonarch_libdir': '/usr/lib',
              'WENDYOS_NM_CONNECTIVITY_URI': distro_default('WENDYOS_NM_CONNECTIVITY_URI'),
              'WENDYOS_NM_CONNECTIVITY_INTERVAL': distro_default('WENDYOS_NM_CONNECTIVITY_INTERVAL')}
    return {**values, **overrides}


def nm_conf(path):
    conf = ConfigParser(interpolation=None)
    conf.optionxform = str
    conf.read(path)
    return conf


def connectivity_confs(installed):
    """Installed NetworkManager config files that carry a [connectivity] section."""
    return sorted(path for path, file in installed.items()
                  if path.startswith('etc/NetworkManager/') and path.endswith('.conf')
                  and nm_conf(file).has_section('connectivity'))


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

    def test_connectivity_check_is_compiled_in(self):
        # Built without concheck, NM ignores [connectivity] without any error.
        self.assertRegex(RECIPE.read_text(), r'(?m)^PACKAGECONFIG:append = "[^"]*\bconcheck\b')

    def test_connectivity_check_ships_enabled(self):
        uri = distro_default('WENDYOS_NM_CONNECTIVITY_URI')
        interval = distro_default('WENDYOS_NM_CONNECTIVITY_INTERVAL')
        check_connectivity_overrides(uri, interval)
        self.assertTrue(uri and int(interval) > 0, (uri, interval))
        with tempfile.TemporaryDirectory() as tmp:
            installed = run_install(install_values(tmp))
            self.assertEqual(connectivity_confs(installed), [CONNECTIVITY_CONF])
            conf = nm_conf(installed[CONNECTIVITY_CONF])
            self.assertEqual(conf.sections(), ['connectivity'])
            # Without an empty response= NM reads every link as a captive
            # portal, penalises them all, and failover stops.
            self.assertEqual(dict(conf['connectivity']),
                             {'response': '', 'uri': uri, 'interval': interval})
            self.assertEqual(installed[CONNECTIVITY_CONF].stat().st_mode & 0o777, 0o644)

    def test_empty_uri_disables_connectivity_check(self):
        check_connectivity_overrides('', 'ignored')
        with tempfile.TemporaryDirectory() as tmp:
            installed = run_install(install_values(tmp, WENDYOS_NM_CONNECTIVITY_URI=''))
            self.assertEqual(connectivity_confs(installed), [])

    def test_url_override_is_written_verbatim(self):
        uri = 'https://check.example.com/204?a=1&b=2|c'
        check_connectivity_overrides(uri, '120')
        with tempfile.TemporaryDirectory() as tmp:
            installed = run_install(install_values(
                tmp, WENDYOS_NM_CONNECTIVITY_URI=uri, WENDYOS_NM_CONNECTIVITY_INTERVAL='120'))
            conf = nm_conf(installed[CONNECTIVITY_CONF])
            self.assertEqual((conf['connectivity']['uri'], conf['connectivity']['interval']),
                             (uri, '120'))

    def test_malformed_override_fails_the_build(self):
        for uri, interval in (
            ('connectivitycheck.gstatic.com/generate_204', '60'),
            ('http://example.com/a b', '60'),
            ('http://example.com/"$(reboot)"', '60'),
            ('http://example.com/204', '1m'),
            ('http://example.com/204', ''),
        ):
            with self.subTest(uri=uri, interval=interval), self.assertRaises(Fatal):
                check_connectivity_overrides(uri, interval)


if __name__ == '__main__':
    unittest.main()
