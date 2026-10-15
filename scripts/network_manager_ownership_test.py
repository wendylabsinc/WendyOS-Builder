#!/usr/bin/env python3
"""Execute the recipe installer for network-manager and journal combinations."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'recipes-core/systemd-conf/systemd-conf_%.bbappend'
FILES = RECIPE.parent / 'files'


class NetworkOwnershipTest(unittest.TestCase):
    def test_install_and_fetch_policy(self):
        recipe = RECIPE.read_text()
        body = re.search(r'^do_install:append\(\) \{\n(.*?)^\}', recipe, re.M | re.S)[1]
        for manager in ('networkmanager', 'systemd-networkd', ''):
            for journal in ('0', '1'):
                with self.subTest(manager=manager, journal=journal), tempfile.TemporaryDirectory() as tmp:
                    values = {
                        'D': tmp, 'UNPACKDIR': str(FILES),
                        'systemd_unitdir': '/usr/lib/systemd',
                        'systemd_system_unitdir': '/usr/lib/systemd/system',
                        'WENDYOS_NET_MANAGER': manager,
                        'WENDYOS_PERSIST_JOURNAL_LOGS': journal,
                    }
                    script = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', lambda m: values[m[1]], body)
                    subprocess.run(['sh', '-eu'], input=script, text=True, check=True)
                    installed = {str(p.relative_to(tmp)): p for p in Path(tmp).rglob('*') if p.is_file()}
                    expected = {
                        'usr/lib/systemd/networkd.conf.d/50-wendyos-agent-policy.conf': 'wendyos-agent-policy.conf',
                    }
                    if manager == 'networkmanager':
                        expected.update({
                            'usr/lib/systemd/system/systemd-networkd-wait-online.service.d/10-wendyos-skip.conf': 'networkd-wait-online-skip.conf',
                            'usr/lib/systemd/system/NetworkManager-wait-online.service.d/10-wendyos-any.conf': 'networkmanager-wait-online-any.conf',
                        })
                        for name in ('80-wired.network', '80-wifi-adhoc.network'):
                            expected[f'usr/lib/systemd/network/{name}.d/50-wendyos-networkmanager.conf'] = 'networkd-networkmanager-unmanaged.conf'
                    elif manager == 'systemd-networkd':
                        expected['usr/lib/systemd/system/systemd-networkd-wait-online.service.d/10-wendyos-any.conf'] = 'networkd-wait-online-any.conf'
                    if journal == '1':
                        expected.update({
                            'usr/lib/systemd/journald.conf.d/10-wendyos-persistent.conf': 'journald-persistent.conf',
                            'usr/lib/systemd/system/var-log.mount': 'var-log.mount',
                        })
                    self.assertEqual(installed.keys(), expected.keys())
                    for target, source in expected.items():
                        self.assertEqual(installed[target].read_bytes(), (FILES / source).read_bytes())
                        self.assertEqual(installed[target].stat().st_mode & 0o777, 0o644)
                    # Evaluate only the recipe's conditional source selections,
                    # to catch an installed drop-in missing from fetched inputs.
                    class Data:
                        def getVar(self, key):
                            return values.get(key)
                    expanded = re.sub(r'\$\{@([^}]+)\}', lambda m: str(eval(m[1], {'d': Data()}))
                                      if 'WENDYOS_NET_MANAGER' in m[1] or 'WENDYOS_PERSIST_JOURNAL_LOGS' in m[1]
                                      else '', recipe)
                    fetched = set(re.findall(r'file://([^\s\"]+)', expanded))
                    self.assertTrue(set(expected.values()).issubset(fetched))
                    self.assertNotIn('wendyos-network-online.preset', fetched)


if __name__ == '__main__':
    unittest.main()
