"""Real Linux-PAM/OpenSSH checks, only inside the disposable test container."""
import os
from pathlib import Path
import subprocess
import unittest

import pexpect

NOTICE = Path('/usr/share/wendyos-access-notice/usg-notice')
PREFIX = 'auth requisite pam_wendy_notice.so\naccount requisite pam_wendy_notice.so\n'


def run(*args, **kw):
    return subprocess.run(args, text=True, check=True, capture_output=True, **kw)


class NoticeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.geteuid() != 0 or not Path('/.dockerenv').exists():
            raise RuntimeError('Run only in the disposable Docker test image')
        run('useradd', '-m', '-s', '/bin/sh', 'noticeuser')
        run('chpasswd', input='noticeuser:Test-only-Local-Password42!\n')
        Path('/etc/pam.d/notice-probe').write_text(PREFIX)
        Path('/etc/pam.d/notice-login').write_text(
            PREFIX + 'auth required pam_unix.so\naccount required pam_unix.so\n')
        login = Path('/etc/pam.d/login')
        login.write_text(PREFIX + login.read_text())
        Path('/etc/pam.d/sshd').write_text(
            PREFIX + 'account required pam_unix.so\nsession required pam_permit.so\n')
        run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', '/tmp/notice-key')
        run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', '/tmp/notice-host')
        auth = Path('/home/noticeuser/.ssh')
        auth.mkdir(mode=0o700)
        (auth / 'authorized_keys').write_text(Path('/tmp/notice-key.pub').read_text())
        run('chown', '-R', 'noticeuser:noticeuser', str(auth))
        (auth / 'authorized_keys').chmod(0o600)
        Path('/tmp/notice-sshd.conf').write_text(Path('/src/usg-notice-sshd.conf').read_text() +
            '\nPort 22222\nListenAddress 127.0.0.1\nHostKey /tmp/notice-host\n'
            'PidFile /tmp/notice-sshd.pid\nLoginGraceTime 10\nLogLevel DEBUG3\n')
        cls.server_log = open('/tmp/notice-sshd.log', 'w')
        cls.server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', '/tmp/notice-sshd.conf'],
                                      stdout=cls.server_log, stderr=cls.server_log)
        import socket, time
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', 22222), timeout=.1):
                    break
            except OSError:
                time.sleep(.05)
        else:
            raise RuntimeError('test sshd did not start')

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=10)
        cls.server_log.close()

    def probe(self, answer='ACCEPT', action='normal', service='notice-probe', password='unused'):
        return subprocess.run(['/tests/pam-probe', service, answer, password, action],
                              text=True, capture_output=True).returncode == 0

    def test_pam_accept(self):
        self.assertTrue(self.probe())

    def test_pam_refusal_cancellation_and_malformed(self):
        for response in ['NO', '', 'accept', ' ACCEPT', 'ACCEPT ', 'ACCEPT\n', 'CANCEL']:
            with self.subTest(response=response):
                self.assertFalse(self.probe(answer=response))

    def test_pam_no_authentication_bypass(self):
        for action in ['account-only', 'silent', 'repeat-refuse', 'change-user']:
            with self.subTest(action=action):
                self.assertFalse(self.probe(action=action))

    def test_pam_login_still_requires_password(self):
        self.assertFalse(self.probe(service='notice-login', password='wrong'))
        self.assertTrue(self.probe(service='notice-login', password='Test-only-Local-Password42!'))
        self.assertFalse(self.probe(service='notice-login', answer='NO', password='Test-only-Local-Password42!'))

    def test_pam_invalid_notice_denies(self):
        original = NOTICE.read_bytes()
        try:
            for content in [b'', b'notice\0hidden', b'x' * 8192]:
                NOTICE.write_bytes(content)
                self.assertFalse(self.probe())
            NOTICE.write_bytes(original)
            NOTICE.chmod(0o666)
            self.assertFalse(self.probe())
            NOTICE.chmod(0o644)
            NOTICE.unlink()
            self.assertFalse(self.probe())
        finally:
            NOTICE.write_bytes(original)
            NOTICE.chmod(0o644)

    def test_local_login_accept(self):
        child = pexpect.spawn('/bin/login', ['noticeuser'], encoding='utf-8', timeout=15)
        child.expect('Type ACCEPT to acknowledge these conditions:')
        self.assertIn('See User Agreement for details.', child.before)
        child.sendline('ACCEPT')
        child.expect('Password:')
        child.sendline('Test-only-Local-Password42!')
        child.expect(r'\$ ')
        child.sendline('exit')
        child.expect(pexpect.EOF)
        child.close()
        self.assertEqual(child.exitstatus, 0)

    def test_local_login_refusal(self):
        child = pexpect.spawn('/bin/login', ['noticeuser'], encoding='utf-8', timeout=15)
        child.expect('Type ACCEPT to acknowledge these conditions:')
        child.sendline('NO')
        child.expect('Login incorrect')
        self.assertNotIn('Password:', child.before)
        child.close(force=True)

    def test_local_preauthenticated_login_denied(self):
        child = pexpect.spawn('/bin/login', ['-f', 'noticeuser'], encoding='utf-8', timeout=15)
        child.expect(pexpect.EOF)
        child.close()
        self.assertNotEqual(child.exitstatus, 0)

    def ssh(self, options=()):
        return pexpect.spawn('ssh', ['-F', '/dev/null', '-p', '22222', '-i', '/tmp/notice-key',
            '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'IdentitiesOnly=yes', *options, 'noticeuser@127.0.0.1', 'echo ACCESS_GRANTED'],
            encoding='utf-8', timeout=15)

    def test_ssh_accept_without_pty(self):
        child = self.ssh(['-T'])
        child.expect('Type ACCEPT to acknowledge these conditions:')
        self.assertIn('See User Agreement for details.', child.before)
        child.sendline('ACCEPT')
        child.expect('ACCESS_GRANTED')
        child.expect(pexpect.EOF)
        child.close()
        self.assertEqual(child.exitstatus, 0)

    def test_ssh_refusal_and_ctrl_c(self):
        for answer in ['NO', '\x03', '\x04']:
            child = self.ssh(['-T'])
            child.expect('Type ACCEPT to acknowledge these conditions:')
            child.send(answer + ('\n' if answer == 'NO' else ''))
            # Repeated keyboard-interactive attempts must never grant access.
            try:
                child.expect('ACCESS_GRANTED', timeout=2)
                self.fail('SSH granted access without acceptance')
            except (pexpect.EOF, pexpect.TIMEOUT):
                pass
            finally:
                child.close(force=True)

    def test_ssh_batch_and_publickey_only_denied(self):
        for options in [['-o', 'BatchMode=yes'], ['-o', 'PreferredAuthentications=publickey']]:
            child = self.ssh(options)
            child.expect(pexpect.EOF)
            self.assertNotIn('ACCESS_GRANTED', child.before)
            child.close()
            self.assertNotEqual(child.exitstatus, 0)

    def test_ssh_no_key_denied(self):
        child = self.ssh(['-o', 'PubkeyAuthentication=no'])
        child.expect(pexpect.EOF)
        self.assertNotIn('ACCESS_GRANTED', child.before)
        child.close()
        self.assertNotEqual(child.exitstatus, 0)

    def test_ssh_expired_account_denied(self):
        run('chage', '-E', '2000-01-01', 'noticeuser')
        try:
            child = self.ssh(['-T'])
            child.expect('Type ACCEPT to acknowledge these conditions:')
            child.sendline('ACCEPT')
            child.expect(pexpect.EOF)
            self.assertNotIn('ACCESS_GRANTED', child.before)
            child.close()
            self.assertNotEqual(child.exitstatus, 0)
        finally:
            run('chage', '-E', '-1', 'noticeuser')

    def test_ssh_locked_password_with_key_and_consent(self):
        run('usermod', '-L', 'noticeuser')
        try:
            self.test_ssh_accept_without_pty()
        finally:
            run('usermod', '-U', 'noticeuser')


if __name__ == '__main__':
    unittest.main(verbosity=2)
