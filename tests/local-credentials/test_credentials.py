"""Exercise the shipped password stack with real Linux PAM and Shadow.

Run only in the disposable image built from this directory's Dockerfile.
The test creates/removes a local account and changes its password.
"""
import os
import pathlib
import re
import shutil
import subprocess
import unittest

STORE = pathlib.Path('/data/etc/wendyos-credential/wendy')
SYNCED = pathlib.Path('/etc/.wendyos-credential-synced')
GOOD = '$6$saltsalt$' + 'a' * 86


def entry(password, last='19000', expire=''):
    """A saved entry: the shadow line with the image-owned fields left empty."""
    return f'wendy:{password}:{last}:::::{expire}:\n'


class CredentialsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if (os.environ.get('WENDY_PAM_TEST_CONTAINER') != '1'
                or not pathlib.Path('/.dockerenv').is_file()
                or os.geteuid() != 0):
            raise RuntimeError('Run through tests/local-credentials/Dockerfile only')

    def setUp(self):
        # Read the lock value from the actual user recipe, not a test fixture.
        recipe = pathlib.Path('/test/wendyos-user.bb').read_text()
        useradd = re.search(r'^USERADD_PARAM:\$\{PN\} = "(.*)"$', recipe, re.M)[1]
        password = re.search(r"-p '([^']*)'", useradd)[1]
        self.assertEqual(password, '*')
        subprocess.run(['useradd', '-m', '-p', password, 'wendy'], check=True)
        self.addCleanup(subprocess.run, ['userdel', '-r', 'wendy'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(shutil.rmtree, '/data/etc', ignore_errors=True)
        self.addCleanup(SYNCED.unlink, missing_ok=True)

    def shadow_fields(self):
        for line in pathlib.Path('/etc/shadow').read_text().splitlines():
            if line.startswith('wendy:'):
                return line.split(':')
        self.fail('wendy is missing from shadow')

    def shadow_password(self):
        return self.shadow_fields()[1]

    def kept(self):
        # What the device owns: password, last change, account expiry.
        f = self.shadow_fields()
        return f'wendy:{f[1]}:{f[2]}:::::{f[7]}:\n'

    def change_password(self, password):
        # Root must not be able to bypass quality checks via normal passwd.
        return subprocess.run(['passwd', 'wendy'],
                              input=(password + '\n') * 6, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=10)

    def test_initial_account_is_locked(self):
        self.assertEqual(self.shadow_password(), '*')
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
                self.assertEqual(self.shadow_password(), '*')

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

    def credential(self, verb, **env):
        return subprocess.run(['/test/wendyos-user-credential.sh', verb],
                              env={**os.environ, **env}, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=10)

    def new_slot(self):
        # A newly installed slot ships the locked entry of its own build day
        # and has never been in step with the store.
        subprocess.run(['usermod', '-p', '*', '-e', '', 'wendy'], check=True)
        subprocess.run(['chage', '-d', '20000', 'wendy'], check=True)
        SYNCED.unlink(missing_ok=True)

    def test_password_survives_a_new_slot(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        provisioned = self.shadow_password()
        saved = self.credential('save')
        self.assertEqual(saved.returncode, 0, saved.stdout)
        self.assertNotIn(provisioned, saved.stdout)
        self.assertEqual(STORE.read_text(), self.kept())
        self.assertEqual(STORE.stat().st_mode & 0o777, 0o600)
        self.assertEqual(STORE.parent.stat().st_mode & 0o777, 0o700)
        self.new_slot()
        restored = self.credential('restore')
        self.assertEqual(restored.returncode, 0, restored.stdout)
        self.assertNotIn(provisioned, restored.stdout)
        self.assertEqual(self.shadow_password(), provisioned)
        self.assertEqual(subprocess.check_output(
            ['passwd', '-S', 'wendy'], text=True).split()[1], 'P')

    def test_lock_survives_a_new_slot(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        subprocess.run(['passwd', '-l', 'wendy'], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        locked = self.shadow_password()
        self.assertEqual(self.credential('save').returncode, 0)
        self.new_slot()
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), locked)
        self.assertTrue(locked.startswith('!'))

    def test_disabled_account_and_password_age_survive_a_new_slot(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        subprocess.run(['chage', '-d', '19000', 'wendy'], check=True)
        subprocess.run(['usermod', '--expiredate', '1', 'wendy'], check=True)
        self.assertEqual(self.credential('save').returncode, 0)
        kept = self.kept()
        self.new_slot()
        self.assertEqual(self.shadow_fields()[7], '')
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.kept(), kept)
        self.assertEqual(self.shadow_fields()[2], '19000')
        self.assertEqual(self.shadow_fields()[7], '1')

    def test_image_keeps_its_aging_limits(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        subprocess.run(['chage', '-m', '0', '-M', '99999', '-W', '7', 'wendy'], check=True)
        self.assertEqual(self.credential('save').returncode, 0)
        self.new_slot()
        # The new image ships stricter limits; the saved entry must not undo them.
        subprocess.run(['chage', '-m', '1', '-M', '60', '-W', '14', '-I', '35', 'wendy'],
                       check=True)
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_fields()[3:7], ['1', '60', '14', '35'])
        self.assertTrue(self.shadow_password().startswith('$6$'))

    def test_unsaved_change_on_this_slot_is_not_undone(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        self.assertEqual(self.credential('save').returncode, 0)
        unlocked = STORE.read_text()
        # The save after the lock never ran (no /data, read-only /data, power cut).
        subprocess.run(['passwd', '-l', 'wendy'], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(STORE.read_text(), unlocked)
        booted = self.credential('restore')
        self.assertEqual(booted.returncode, 0, booted.stdout)
        self.assertIn('not saved', booted.stdout)
        self.assertTrue(self.shadow_password().startswith('!'))
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertEqual(STORE.read_text(), self.kept())

    def test_rollback_slot_takes_the_newer_saved_entry(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        self.assertEqual(self.credential('save').returncode, 0)
        # The other slot saved a newer password while this one was not booted.
        STORE.write_text(entry(GOOD, last='19500'))
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), GOOD)
        self.assertEqual(self.shadow_fields()[2], '19500')

    def test_entry_chpasswd_would_reject_is_not_kept(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        self.assertEqual(self.credential('save').returncode, 0)
        for bad in ('!!' + GOOD, '$1$saltsalt$' + 'a' * 22, 'x', '!!', '$6$short$abc'):
            with self.subTest(bad=bad):
                subprocess.run(['usermod', '-p', bad, 'wendy'], check=True)
                self.assertEqual(self.credential('save').returncode, 0)
                self.assertFalse(STORE.exists())
                # Nothing saved for it must come back or block the next boot.
                self.assertEqual(self.credential('restore').returncode, 0)
                self.assertEqual(self.shadow_password(), bad)
        for good in ('!' + GOOD, '!*', '!', '$y$j9T$' + 'a' * 22 + '$' + 'b' * 43,
                     '$5$rounds=5000$salt$' + 'c' * 43):
            with self.subTest(good=good):
                subprocess.run(['usermod', '-p', good, 'wendy'], check=True)
                self.assertEqual(self.credential('save').returncode, 0)
                self.assertEqual(STORE.read_text(), self.kept())

    def test_restore_passes_the_entry_on_stdin_and_stops_on_failure(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        self.assertEqual(self.credential('save').returncode, 0)
        saved = STORE.read_text()
        provisioned = self.shadow_password()
        stub = pathlib.Path('/tmp/stub')
        stub.mkdir()
        self.addCleanup(shutil.rmtree, stub, ignore_errors=True)
        for tool in ('chpasswd', 'chage'):
            (stub / tool).write_text('#!/bin/sh\necho "$0 $*" >> /tmp/stub/argv\n'
                                     f'exec /usr/sbin/{tool} "$@"\n'
                                     if tool == 'chpasswd' else
                                     '#!/bin/sh\necho "$0 $*" >> /tmp/stub/argv\n'
                                     f'exec /usr/bin/{tool} "$@"\n')
            (stub / tool).chmod(0o755)
        self.new_slot()
        path = '/tmp/stub:' + os.environ['PATH']
        self.assertEqual(self.credential('restore', PATH=path).returncode, 0)
        self.assertEqual(self.shadow_password(), provisioned)
        argv = (stub / 'argv').read_text()
        self.assertIn('chpasswd -e', argv)
        self.assertNotIn(provisioned, argv)
        self.assertNotIn('$6$', argv)
        # A tool that fails must fail the restore and leave the store alone,
        # so that the save after it cannot replace a good entry.
        self.new_slot()
        (stub / 'chpasswd').write_text('#!/bin/sh\nexit 1\n')
        failed = self.credential('restore', PATH=path)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(STORE.read_text(), saved)
        self.assertFalse(SYNCED.exists())

    def test_leftover_temporary_file_does_not_widen_the_mode(self):
        STORE.parent.mkdir(parents=True)
        leftover = STORE.parent / 'wendy.tmp'
        leftover.write_text('stale\n')
        leftover.chmod(0o644)
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertEqual(STORE.stat().st_mode & 0o777, 0o600)
        self.assertEqual(SYNCED.stat().st_mode & 0o777, 0o600)

    def test_fresh_device_stays_locked(self):
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), '*')
        self.assertFalse(STORE.exists())

    def test_old_shared_password_is_never_kept(self):
        # The entry every image shipped before the account was locked.
        legacy = subprocess.check_output(
            ['perl', '-e', 'print crypt("wendy", q{$6$5ixFr0sKRtsKKKhY$})'],
            text=True)
        self.assertTrue(legacy.startswith('$6$5ixFr0sKRtsKKKhY$'), legacy)
        for legacy_entry in (legacy, '!' + legacy):
            with self.subTest(locked=legacy_entry.startswith('!')):
                # A saved good password must not outlive the bad one either.
                STORE.parent.mkdir(parents=True, exist_ok=True)
                STORE.write_text(entry(GOOD))
                subprocess.run(['usermod', '-p', legacy_entry, 'wendy'], check=True)
                self.assertEqual(self.credential('save').returncode, 0)
                self.assertFalse(STORE.exists())
                self.new_slot()
                STORE.write_text(entry(legacy_entry))
                restored = self.credential('restore')
                self.assertEqual(restored.returncode, 0)
                self.assertIn('old shared password', restored.stdout)
                self.assertEqual(self.shadow_password(), '*')

    def test_unusable_entries_are_ignored(self):
        STORE.parent.mkdir(parents=True)
        self.new_slot()
        for content in ('', '\n', 'x:y\n', '-o\n', GOOD + '\n',
                        entry(GOOD).replace('wendy:', 'root:'),
                        entry(''),
                        entry('$6$ab cd'),
                        entry(GOOD, last='x'),
                        entry(GOOD, expire='-1'),
                        f'wendy:{GOOD}:19000:0:99999:7:::\n',
                        f'wendy:{GOOD}:19000:::::1:reserved\n',
                        f'wendy:{GOOD}:19000:::::\n',
                        f'wendy:{GOOD}:19000:::::::\n'):
            with self.subTest(content=content):
                STORE.write_text(content)
                restored = self.credential('restore')
                self.assertEqual(restored.returncode, 0)
                self.assertIn('not a saved wendy entry', restored.stdout)
                self.assertEqual(self.shadow_password(), '*')
                self.assertEqual(self.shadow_fields()[2], '20000')
        # The same shape with nothing wrong in it is restored.
        STORE.write_text(entry(GOOD))
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), GOOD)
        self.new_slot()
        # A deleted password is a login without one. It is not kept, and the
        # entry saved before it must not come back on the next slot.
        subprocess.run(['passwd', '-d', 'wendy'], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(self.shadow_password(), '')
        STORE.write_text(entry(GOOD))
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertFalse(STORE.exists())

    def test_entry_that_cannot_be_updated_is_removed(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        self.assertEqual(self.credential('save').returncode, 0)
        subprocess.run(['passwd', '-l', 'wendy'], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # The write beside the store fails; the unlocked entry must not stay.
        (STORE.parent / 'wendy.tmp').mkdir()
        self.addCleanup(shutil.rmtree, STORE.parent / 'wendy.tmp',
                        ignore_errors=True)
        self.assertNotEqual(self.credential('save').returncode, 0)
        self.assertFalse(STORE.exists())

    def test_restore_leaves_other_accounts_alone(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        self.assertEqual(self.credential('save').returncode, 0)
        before = [line for line in pathlib.Path('/etc/shadow').read_text().splitlines()
                  if not line.startswith('wendy:')]
        self.new_slot()
        self.assertEqual(self.credential('restore').returncode, 0)
        after = [line for line in pathlib.Path('/etc/shadow').read_text().splitlines()
                 if not line.startswith('wendy:')]
        self.assertEqual(before, after)

    def test_nothing_is_written_without_the_data_partition(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        for verb in ('save', 'restore'):
            with self.subTest(verb=verb):
                result = self.credential(verb, WENDYOS_DATA_MOUNT='/tmp/nodata')
                self.assertNotEqual(result.returncode, 0)
        self.assertFalse(pathlib.Path('/tmp/nodata').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
