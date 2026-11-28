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

    def test_image_guard_rejects_console_autologin(self):
        for name in ['usr/lib/credstore/agetty.autologin',
                     'etc/credstore/tty.serial.ttyS0.agetty.autologin',
                     'usr/lib/credstore/login.noauth']:
            with self.subTest(name=name):
                self.setUp()
                self.valid_image()
                path = self.root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('root')
                with self.assertRaisesRegex(ValueError, 'console autologin'):
                    self.guard()
        self.setUp()
        self.valid_image()
        dropin = self.root / 'etc/systemd/system/serial-getty@.service.d/auto.conf'
        dropin.parent.mkdir(parents=True)
        dropin.write_text('[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root - $TERM\n')
        with self.assertRaisesRegex(ValueError, 'console autologin'):
            self.guard()

    def test_image_guard_accepts_unrelated_credentials_and_units(self):
        self.valid_image()
        for name, text in [('usr/lib/credstore/agetty.noclear', '1'),
                           ('usr/lib/systemd/system/serial-getty@.service',
                            '[Service]\nExecStart=-/sbin/agetty --noclear - $TERM\n'),
                           ('etc/ssh/sshd_config.d/10-sftp.conf',
                            'Match Group sftp\n    ForceCommand internal-sftp\n'),
                           ('etc/default/ssh', 'SSHD_OPTS=""\n')]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.guard()

    def test_image_guard_rejects_ssh_overrides(self):
        cases = [('etc/ssh/sshd_config.d/10-x.conf',
                  'Match User wendy\n    AuthenticationMethods keyboard-interactive\n', 'Match block'),
                 ('etc/ssh/sshd_config.d/10-x.conf',
                  'match all\nPubkeyAuthentication=no\n', 'Match block'),
                 ('etc/ssh/sshd_config.d/10-x.conf', 'PAMServiceName sudo\n', 'PAMServiceName'),
                 ('etc/default/ssh', 'SSHD_OPTS="-o AuthenticationMethods=any"\n', 'SSHD_OPTS'),
                 ('etc/default/ssh', 'SSHD_OPTS=-f/etc/ssh/other\n', 'SSHD_OPTS')]
        for name, text, message in cases:
            with self.subTest(text=text):
                self.setUp()
                self.valid_image()
                path = self.root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
                with self.assertRaisesRegex(ValueError, message):
                    self.guard()
        self.setUp()
        self.valid_image()
        path = self.root / 'etc/ssh/sshd_config'
        path.write_text(path.read_text() + 'Match Address 10.0.0.0/8\n    PasswordAuthentication yes\n')
        with self.assertRaisesRegex(ValueError, 'Match block'):
            self.guard()


if __name__ == '__main__':
    unittest.main(verbosity=2)
