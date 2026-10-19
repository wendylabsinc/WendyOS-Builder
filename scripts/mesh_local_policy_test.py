#!/usr/bin/env python3
"""Exercise recipe installation and reject images with ineffective mesh policy."""
from pathlib import Path
import importlib.util
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'recipes-core/wendyos-mesh-policy/wendyos-mesh-policy_1.0.bb'
spec = importlib.util.spec_from_file_location('policy', ROOT / 'scripts/check_mesh_local_policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        body = re.search(r'^do_install\(\) \{\n(.*?)^\}', RECIPE.read_text(), re.M | re.S)[1]
        for key, value in {'D': str(self.root), 'UNPACKDIR': str(RECIPE.parent / 'files'),
                           'nonarch_libdir': '/usr/lib', 'nonarch_base_libdir': '/usr/lib',
                           'systemd_unitdir': '/usr/lib/systemd',
                           'systemd_system_unitdir': '/usr/lib/systemd/system'}.items():
            body = body.replace('${' + key + '}', value)
        subprocess.run(['sh', '-eu'], input=body, text=True, check=True)
        self.write('usr/lib/systemd/systemd-sysctl', '#!/bin/sh\nexit 0\n').chmod(0o755)
        self.write('usr/lib/systemd/system/systemd-sysctl.service', '[Service]\nExecStart=/usr/lib/systemd/systemd-sysctl\n')
        self.write('usr/lib/systemd/system/systemd-udevd.service', '[Service]\nExecStart=/usr/lib/systemd/systemd-udevd\n')
        shutil.copy(ROOT / 'recipes-core/wendyos-agent/files/wendyos-agent.service', self.root / 'usr/lib/systemd/system')

    def write(self, relative, value):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        return path

    def test_installed_policy_and_agent_dependency(self):
        self.assertEqual(policy.validate(self.root), [])
        assignments = list(policy.assignments((self.root / 'usr/lib/sysctl.d/90-wendy-mesh.conf').read_text()))
        self.assertEqual(assignments, [(policy.KEY, '0')])  # IPv6 and ARP unchanged.
        agent = (ROOT / 'recipes-core/wendyos-agent/wendyos-agent_1.0.bb').read_text()
        self.assertRegex(agent, r'RDEPENDS:\$\{PN\}:append = " wendyos-mesh-policy"')

    def test_missing_each_required_component(self):
        for relative in ['usr/lib/sysctl.d/90-wendy-mesh.conf', 'usr/lib/udev/rules.d/90-wendy-mesh.rules',
                         'usr/lib/systemd/systemd-sysctl', 'usr/lib/systemd/system/systemd-sysctl.service',
                         'usr/lib/systemd/system/systemd-udevd.service',
                         'usr/lib/systemd/system/wendyos-agent.service.d/20-mesh-sysctl.conf']:
            with self.subTest(relative=relative):
                path = self.root / relative
                content = path.read_bytes()
                mode = path.stat().st_mode
                path.unlink()
                self.assertTrue(policy.validate(self.root))
                path.write_bytes(content)
                path.chmod(mode)

    def test_non_executable_helper_is_rejected(self):
        (self.root / 'usr/lib/systemd/systemd-sysctl').chmod(0o644)
        self.assertTrue(policy.validate(self.root))

    def test_rejects_later_value_and_same_basename_override(self):
        for relative in ['usr/lib/sysctl.d/99-vendor.conf', 'etc/sysctl.d/90-wendy-mesh.conf', 'run/sysctl.d/90-wendy-mesh.conf']:
            with self.subTest(relative=relative):
                path = self.write(relative, 'net/bridge/bridge-nf-call-iptables = 1\n')
                self.assertTrue(policy.validate(self.root))
                path.unlink()
        # An explicit assignment beats a glob; a generic vendor glob must not
        # cause a false rejection of the required explicit zero.
        self.write('usr/lib/sysctl.d/99-vendor.conf', 'net.bridge.* = 1\n')
        self.assertEqual(policy.validate(self.root), [])

    def test_rejects_policy_or_event_rule_mask(self):
        for relative in ['etc/sysctl.d/90-wendy-mesh.conf', 'etc/udev/rules.d/90-wendy-mesh.rules']:
            with self.subTest(relative=relative):
                path = self.root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.symlink_to('/dev/null')
                self.assertTrue(policy.validate(self.root))
                path.unlink()

    def test_wrong_module_or_event_will_not_apply(self):
        path = self.root / 'usr/lib/udev/rules.d/90-wendy-mesh.rules'
        text = path.read_text()
        for old, new in [('"br_netfilter"', '"bridge"'), ('"add"', '"remove"'), ('/net/bridge/bridge-nf-call-iptables', '/net/ipv6')]:
            with self.subTest(new=new):
                path.write_text(text.replace(old, new))
                self.assertTrue(policy.validate(self.root))
        path.write_text(text)

    def test_reset_of_ordering_is_rejected(self):
        self.write('etc/systemd/system/wendyos-agent.service.d/99-bad.conf', '[Unit]\nAfter=\nWants=\n')
        self.assertTrue(policy.validate(self.root))

    def test_gate_is_wired_to_actual_image(self):
        image = (ROOT / 'recipes-core/images/wendyos-image.bb').read_text()
        self.assertIn('inherit mesh-local-policy-check', image)
        recipe = (ROOT / 'classes/mesh-local-policy-check.bbclass').read_text()
        self.assertIn('do_rootfs[postfuncs] += "wendyos_check_mesh_local_policy"', recipe)

    @unittest.skipUnless(os.getenv('WENDY_TEST_SYSTEMD_POLICY') == '1', 'requires disposable Linux mount namespace and systemd tools')
    def test_real_systemd_applies_boot_and_late_policy(self):
        # Run only in a disposable privileged container. Bind a fake /proc/sys/net
        # so no host or container network policy can be modified by this test.
        helper = Path('/usr/lib/systemd/systemd-sysctl')
        self.assertTrue(helper.is_file())
        fake = self.root / 'fake-sys'
        bridge = fake / 'bridge'
        bridge.mkdir(parents=True)
        ipv4 = bridge / 'bridge-nf-call-iptables'
        ipv6 = bridge / 'bridge-nf-call-ip6tables'
        ipv4.write_text('1\n')
        ipv6.write_text('1\n')
        config = self.root / 'usr/lib/sysctl.d/90-wendy-mesh.conf'
        script = '''set -eu
mount --make-rprivate /
mount --bind "$1" /proc/sys/net
"$2" "$3"
test "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables)" = 0
test "$(cat /proc/sys/net/bridge/bridge-nf-call-ip6tables)" = 1
rm /proc/sys/net/bridge/bridge-nf-call-iptables
"$2" "$3"
printf '1\\n' > /proc/sys/net/bridge/bridge-nf-call-iptables
"$2" --prefix=/net/bridge/bridge-nf-call-iptables "$3"
test "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables)" = 0
test "$(cat /proc/sys/net/bridge/bridge-nf-call-ip6tables)" = 1
'''
        subprocess.run(['unshare', '--mount', 'sh', '-c', script, 'policy-test', str(fake), str(helper), str(config)], check=True)
        rule = self.root / 'usr/lib/udev/rules.d/90-wendy-mesh.rules'
        subprocess.run(['udevadm', 'verify', str(rule)], check=True)


if __name__ == '__main__':
    unittest.main()
