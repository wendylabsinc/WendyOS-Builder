"""Exercise recipe install functions and the image guard on temporary roots."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREFIX = 'auth requisite pam_wendy_notice.so\naccount requisite pam_wendy_notice.so\n'


def install_function(relative, root, enabled):
    text = (ROOT / relative).read_text()
    body = re.search(r'do_install:append:class-target\(\) \{\n(.*?)\n\}', text, re.S)[1]
    values = {'D': str(root), 'sysconfdir': '/etc', 'WENDYOS_USG_NOTICE': str(enabled),
              'UNPACKDIR': str(ROOT / 'recipes-connectivity/openssh/files')}
    for key, value in values.items():
        body = body.replace('${' + key + '}', value)
    return subprocess.run(['sh', '-ec', 'bbfatal() { exit 42; }\n' + body],
                          capture_output=True, text=True)


class RecipeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'etc/pam.d').mkdir(parents=True)
        (self.root / 'etc/ssh').mkdir()
        self.login = 'auth sufficient pam_unix.so\naccount include common-account\nsession include common-session\n'
        self.ssh = 'auth include common-auth\naccount include common-account\nsession include common-session\n'
        (self.root / 'etc/pam.d/login').write_text(self.login)
        (self.root / 'etc/pam.d/sshd').write_text(self.ssh)
        for name in ['sshd_config', 'sshd_config_readonly']:
            (self.root / 'etc/ssh' / name).write_text('KbdInteractiveAuthentication no\nInclude /etc/ssh/sshd_config.d/*.conf\n')

    def install(self, enabled=1):
        for recipe in ['recipes-extended/shadow/shadow-usg-notice.inc',
                       'recipes-connectivity/openssh/openssh_%.bbappend']:
            result = install_function(recipe, self.root, enabled)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_ordinary_profile_unchanged(self):
        self.install(0)
        self.assertEqual((self.root / 'etc/pam.d/login').read_text(), self.login)
        self.assertEqual((self.root / 'etc/pam.d/sshd').read_text(), self.ssh)

    def test_enabled_recipe_preserves_account_and_session(self):
        self.install()
        self.assertEqual((self.root / 'etc/pam.d/login').read_text(), PREFIX + self.login)
        self.assertEqual((self.root / 'etc/pam.d/sshd').read_text(),
                         PREFIX + self.ssh.split('\n', 1)[1])
        header = (ROOT / 'recipes-connectivity/openssh/files/usg-notice-sshd.conf').read_text()
        for name in ['sshd_config', 'sshd_config_readonly']:
            config = self.root / 'etc/ssh' / name
            self.assertTrue(config.read_text().startswith(header))
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_missing_pam_rejected(self):
        for recipe, service in [('recipes-extended/shadow/shadow-usg-notice.inc', 'login'),
                                ('recipes-connectivity/openssh/openssh_%.bbappend', 'sshd')]:
            (self.root / 'etc/pam.d' / service).unlink()
            self.assertEqual(install_function(recipe, self.root, 1).returncode, 42)

    def test_incomplete_pam_rejected(self):
        for recipe, service in [('recipes-extended/shadow/shadow-usg-notice.inc', 'login'),
                                ('recipes-connectivity/openssh/openssh_%.bbappend', 'sshd')]:
            for content in ['', 'auth include common-auth\n', 'account include common-account\n']:
                (self.root / 'etc/pam.d' / service).write_text(content)
                self.assertEqual(install_function(recipe, self.root, 1).returncode, 42)

    def guard(self):
        result = subprocess.run(['python3', str(ROOT / 'scripts/check_usg_access_notice.py'),
                                 '--rootfs', str(self.root), '--ssh'], capture_output=True, text=True)
        if result.returncode:
            raise ValueError(result.stderr)

    def valid_image(self):
        self.install()
        for name in ['lib/security/pam_wendy_notice.so', 'usr/share/wendyos-access-notice/usg-notice',
                     'bin/login.shadow']:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture')
        (self.root / 'bin/login').symlink_to('/etc/alternatives/login')
        (self.root / 'etc/alternatives').mkdir()
        (self.root / 'etc/alternatives/login').symlink_to('/bin/login.shadow')

    def test_image_guard_resolves_image_absolute_alternatives(self):
        self.valid_image()
        self.guard()

    def test_image_guard_rejects_missing_module(self):
        self.valid_image()
        (self.root / 'lib/security/pam_wendy_notice.so').unlink()
        with self.assertRaisesRegex(ValueError, 'PAM module'):
            self.guard()

    def test_image_guard_rejects_symlink_cycle(self):
        self.valid_image()
        path = self.root / 'etc/alternatives/login'
        path.unlink()
        path.symlink_to('/bin/login')
        with self.assertRaisesRegex(ValueError, 'symlink cycle'):
            self.guard()

    def test_image_guard_rejects_symlink_escape(self):
        self.valid_image()
        path = self.root / 'etc/alternatives/login'
        path.unlink()
        path.symlink_to('../../../login.shadow')
        with self.assertRaisesRegex(ValueError, 'escapes IMAGE_ROOTFS'):
            self.guard()

    def test_image_guard_rejects_auth_bypass(self):
        self.valid_image()
        path = self.root / 'etc/pam.d/login'
        path.write_text('auth sufficient pam_permit.so\n' + path.read_text())
        with self.assertRaisesRegex(ValueError, 'precede every'):
            self.guard()

    def test_image_guard_rejects_ssh_override_before_header(self):
        self.valid_image()
        path = self.root / 'etc/ssh/sshd_config_readonly'
        path.write_text('AuthenticationMethods any\n' + path.read_text())
        with self.assertRaisesRegex(ValueError, 'must be first'):
            self.guard()


if __name__ == '__main__':
    unittest.main(verbosity=2)
