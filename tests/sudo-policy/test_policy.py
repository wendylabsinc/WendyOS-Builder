"""Exercise the shipped sudo policy only inside the disposable test image."""

import os
from pathlib import Path
import secrets
import subprocess
import unittest


class SudoPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not Path('/.dockerenv').exists() or os.geteuid() != 0:
            raise RuntimeError('Run through tests/sudo-policy/Dockerfile only')

    def setUp(self):
        # Ephemeral test credentials, never a password shipped in an OS image.
        self.password = secrets.token_urlsafe(32)
        subprocess.run(['chpasswd'], input=f'wendy:{self.password}\n',
                       text=True, check=True)
        subprocess.run(['runuser', '-u', 'wendy', '--', 'sudo', '-K'], check=True)

    def as_user(self, *args, user='wendy', password=None):
        return subprocess.run(['runuser', '-u', user, '--', *args],
                              input=password, text=True, capture_output=True,
                              timeout=20)

    def test_policy_parses(self):
        subprocess.run(['visudo', '--check'], check=True)

    def test_noninteractive_elevation_requires_authentication(self):
        result = self.as_user('sudo', '-n', '/usr/bin/id', '-u')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('password is required', result.stderr)

    def test_correct_caller_password_allows_root_administration(self):
        result = self.as_user('sudo', '-S', '-p', '', '/usr/bin/id', '-u',
                              password=self.password + '\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '0')

    def test_incorrect_password_cannot_elevate(self):
        result = self.as_user('sudo', '-S', '-p', '', '/usr/bin/id', '-u',
                              password='incorrect\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_locked_account_cannot_elevate(self):
        subprocess.run(['passwd', '--lock', 'wendy'], check=True,
                       capture_output=True)
        result = self.as_user('sudo', '-S', '-p', '', '/usr/bin/id', '-u',
                              password=self.password + '\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_success_does_not_authenticate_the_next_command(self):
        # Both invocations share the same shell, so a normal sudo timestamp
        # would let the second command run. No new password is supplied to it.
        result = self.as_user('/bin/sh', '-c',
                              "sudo -S -p '' /usr/bin/id -u && sudo -n /usr/bin/id -u",
                              password=self.password + '\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), '0')
        self.assertIn('password is required', result.stderr)

    def test_sudo_validate_does_not_authenticate_the_next_command(self):
        result = self.as_user('/bin/sh', '-c',
                              "sudo -S -p '' -v && sudo -n /usr/bin/id -u",
                              password=self.password + '\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('password is required', result.stderr)

    def test_unrelated_user_has_no_administrator_grant(self):
        result = self.as_user('sudo', '-n', '/usr/bin/id', '-u', user='unrelated')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_direct_runas_other_user_is_not_granted(self):
        result = self.as_user('sudo', '-S', '-p', '', '-u', 'unrelated',
                              '/usr/bin/id', '-u', password=self.password + '\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main(verbosity=2)
