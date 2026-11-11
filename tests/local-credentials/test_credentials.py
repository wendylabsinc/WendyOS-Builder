"""Exercise the shipped password stack with real Linux PAM and Shadow.

Run only in the disposable image built from this directory's Dockerfile.
The test creates/removes a local account and changes its password.
"""
import os
import pathlib
import re
import subprocess
import unittest


class CredentialsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if (os.environ.get('WENDY_PAM_TEST_CONTAINER') != '1'
                or not pathlib.Path('/.dockerenv').is_file()
                or os.geteuid() != 0):
            raise unittest.SkipTest('requires the disposable root Docker fixture')

    def setUp(self):
        # Read the lock value from the actual user recipe, not a test fixture.
        recipe = pathlib.Path('/test/wendyos-user.bb').read_text()
        useradd = re.search(r'^USERADD_PARAM:\$\{PN\} = "(.*)"$', recipe, re.M)[1]
        password = re.search(r"-p '([^']*)'", useradd)[1]
        self.assertEqual(password, '!')
        subprocess.run(['useradd', '-m', '-p', password, 'wendy'], check=True)
        self.addCleanup(subprocess.run, ['userdel', '-r', 'wendy'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def shadow_password(self):
        for line in pathlib.Path('/etc/shadow').read_text().splitlines():
            if line.startswith('wendy:'):
                return line.split(':')[1]
        self.fail('wendy is missing from shadow')

    def change_password(self, password):
        # Root must not be able to bypass quality checks via normal passwd.
        return subprocess.run(['passwd', 'wendy'],
                              input=(password + '\n') * 6, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=10)

    def test_initial_account_is_locked(self):
        self.assertEqual(self.shadow_password(), '!')
        status = subprocess.check_output(['passwd', '-S', 'wendy'], text=True)
        self.assertEqual(status.split()[1], 'L')

    def test_root_cannot_install_weak_passwords(self):
        cases = {
            'legacy shared password': 'wendy',
            '14 characters': 'Yq7!mZ2#vK9@xL',
            'missing uppercase': 'yq7!mz2#vk9@xl6$p',
            'missing lowercase': 'YQ7!MZ2#VK9@XL6$P',
            'missing digit': 'Yqv!mZk#vKw@xLa$p',
            'missing special character': 'Yq7AmZ2BvK9CxL6Dp',
        }
        for reason, candidate in cases.items():
            with self.subTest(reason=reason):
                result = self.change_password(candidate)
                self.assertNotEqual(result.returncode, 0, reason)
                self.assertEqual(self.shadow_password(), '!')

    def test_provision_change_and_relock(self):
        result = self.change_password('Yq7!mZ2#vK9@xL6$p')
        self.assertEqual(result.returncode, 0, result.stderr)
        initial_hash = self.shadow_password()
        self.assertTrue(initial_hash.startswith('$6$'))
        self.assertEqual(subprocess.check_output(
            ['passwd', '-S', 'wendy'], text=True).split()[1], 'P')
        rejected = self.change_password('weak')
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(self.shadow_password(), initial_hash)
        changed = self.change_password('Tn8@bR4%wJ2!hV9&c')
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertNotEqual(self.shadow_password(), initial_hash)
        subprocess.run(['passwd', '-l', 'wendy'], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertTrue(self.shadow_password().startswith('!'))
        self.assertEqual(subprocess.check_output(
            ['passwd', '-S', 'wendy'], text=True).split()[1], 'L')

    def test_user_password_change_enforces_same_policy(self):
        original = 'Yq7!mZ2#vK9@xL6$p'
        self.assertEqual(self.change_password(original).returncode, 0)
        old_hash = self.shadow_password()
        result = subprocess.run(['runuser', '-u', 'wendy', '--', 'passwd'],
                                input=original + '\n' + 'weak\n' * 6,
                                text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.shadow_password(), old_hash)
        replacement = 'Tn8@bR4%wJ2!hV9&c'
        result = subprocess.run(['runuser', '-u', 'wendy', '--', 'passwd'],
                                input=original + '\n' + (replacement + '\n') * 2,
                                text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.shadow_password(), old_hash)


if __name__ == '__main__':
    unittest.main(verbosity=2)
