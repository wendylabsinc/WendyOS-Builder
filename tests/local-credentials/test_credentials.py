"""Exercise the shipped password stack with real Linux PAM and Shadow.

Run only in the disposable image built from this directory's Dockerfile.
The test creates/removes a local account and changes its password.
"""
import os
import pathlib
import re
import shutil
import subprocess
import time
import unittest
import uuid

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

    def kept(self, password=None):
        # What the device owns: password, last change, account expiry.
        f = self.shadow_fields()
        return f'wendy:{f[1] if password is None else password}:{f[2]}:::::{f[7]}:\n'

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

    # --- A/B persistence of the wendy entry ---------------------------------

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

    def slot(self):
        """This slot's shadow file and record, to come back to it later."""
        return pathlib.Path('/etc/shadow').read_text(), SYNCED.read_text()

    def boot(self, slot):
        pathlib.Path('/etc/shadow').write_text(slot[0])
        SYNCED.write_text(slot[1])

    def stored(self):
        return STORE.read_text().splitlines()[0] + '\n'

    def token(self):
        return STORE.read_text().splitlines()[1]

    def other_slot_saves(self, line):
        # Another slot, booted later, saves: a new token with the entry.
        STORE.parent.mkdir(parents=True, exist_ok=True)
        STORE.write_text(line + str(uuid.uuid4()) + '\n')

    def provision(self):
        self.assertEqual(self.change_password('Yq7!mZ2#vK9@xL6$p').returncode, 0)
        self.assertEqual(self.credential('save').returncode, 0)
        return self.shadow_password()

    def stub(self, **tools):
        """Put shell snippets in front of the real tools, one per name."""
        stub = pathlib.Path('/tmp/stub')
        shutil.rmtree(stub, ignore_errors=True)
        stub.mkdir()
        self.addCleanup(shutil.rmtree, stub, ignore_errors=True)
        for name, body in tools.items():
            real = shutil.which(name)
            (stub / name).write_text(f'#!/bin/sh\n{body}\nexec {real} "$@"\n')
            (stub / name).chmod(0o755)
        return '/tmp/stub:' + os.environ['PATH']

    def test_password_survives_a_new_slot(self):
        provisioned = self.provision()
        self.assertEqual(self.stored(), self.kept())
        self.assertRegex(self.token(), r'^[0-9a-f-]{36}$')
        self.assertEqual(STORE.stat().st_mode & 0o777, 0o600)
        self.assertEqual(STORE.parent.stat().st_mode & 0o777, 0o700)
        self.new_slot()
        restored = self.credential('restore')
        self.assertEqual(restored.returncode, 0, restored.stdout)
        self.assertNotIn(provisioned, restored.stdout)
        self.assertEqual(self.shadow_password(), provisioned)
        self.assertEqual(subprocess.check_output(
            ['passwd', '-S', 'wendy'], text=True).split()[1], 'P')

    def test_every_write_gets_a_new_token(self):
        self.provision()
        first = self.token()
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertEqual(self.token(), first)
        subprocess.run(['passwd', '-l', 'wendy'], check=True, capture_output=True)
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertNotEqual(self.token(), first)

    def test_lock_survives_a_new_slot(self):
        self.provision()
        subprocess.run(['passwd', '-l', 'wendy'], check=True, capture_output=True)
        locked = self.shadow_password()
        self.assertEqual(self.credential('save').returncode, 0)
        self.new_slot()
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), locked)

    def test_expiry_and_password_age_survive_a_new_slot(self):
        self.provision()
        subprocess.run(['chage', '-d', '19000', 'wendy'], check=True)
        subprocess.run(['usermod', '--expiredate', '1', 'wendy'], check=True)
        self.assertEqual(self.credential('save').returncode, 0)
        kept = self.kept()
        self.new_slot()
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.kept(), kept)
        self.assertEqual(self.shadow_fields()[2], '19000')
        self.assertEqual(self.shadow_fields()[7], '1')

    def test_image_keeps_its_aging_limits(self):
        self.provision()
        subprocess.run(['chage', '-m', '0', '-M', '99999', '-W', '7', 'wendy'], check=True)
        self.assertEqual(self.credential('save').returncode, 0)
        self.new_slot()
        # The new image ships stricter limits; the saved entry must not undo them.
        subprocess.run(['chage', '-m', '1', '-M', '60', '-W', '14', '-I', '35', 'wendy'],
                       check=True)
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_fields()[3:7], ['1', '60', '14', '35'])
        self.assertTrue(self.shadow_password().startswith('$6$'))

    def test_fresh_device_stays_locked(self):
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), '*')
        self.assertFalse(STORE.exists())

    def test_unsaved_change_on_this_slot_is_kept(self):
        self.provision()
        # The save after the lock never ran (power cut).
        subprocess.run(['passwd', '-l', 'wendy'], check=True, capture_output=True)
        booted = self.credential('restore')
        self.assertEqual(booted.returncode, 0, booted.stdout)
        self.assertIn('not saved', booted.stdout)
        self.assertTrue(self.shadow_password().startswith('!'))
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertEqual(self.stored(), self.kept())

    def test_newer_save_on_another_slot_beats_an_unsaved_change(self):
        self.provision()
        # This slot changes its password, but the save never happens.
        subprocess.run(['usermod', '-p', GOOD, 'wendy'], check=True)
        # A slot booted later locks the account and disables it.
        self.other_slot_saves(entry('!' + GOOD, last='20100', expire='1'))
        restored = self.credential('restore')
        self.assertEqual(restored.returncode, 0, restored.stdout)
        self.assertNotIn('not saved', restored.stdout)
        self.assertEqual(self.shadow_password(), '!' + GOOD)
        self.assertEqual(self.shadow_fields()[7], '1')

    def test_same_content_saved_again_elsewhere_still_wins(self):
        provisioned = self.provision()
        subprocess.run(['passwd', '-l', 'wendy'], check=True, capture_output=True)
        self.assertEqual(self.credential('save').returncode, 0)
        # Slot A unlocks, but the save never happens.
        subprocess.run(['passwd', '-u', 'wendy'], check=True, capture_output=True)
        slot_a = self.slot()
        # Slot B, booted later, unlocks and locks again, both saved. The store
        # ends on the same content as A last saw.
        self.new_slot()
        self.assertEqual(self.credential('restore').returncode, 0)
        for flag in ('-u', '-l'):
            subprocess.run(['passwd', flag, 'wendy'], check=True, capture_output=True)
            self.assertEqual(self.credential('save').returncode, 0)
        # Rolled back to A: B's later lock wins over A's unsaved unlock.
        self.boot(slot_a)
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), '!' + provisioned)

    def test_rollback_slot_takes_the_newer_saved_entry(self):
        self.provision()
        self.other_slot_saves(entry(GOOD, last='19500'))
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), GOOD)
        self.assertEqual(self.shadow_fields()[2], '19500')

    def test_store_gone_after_a_sync_fails_closed(self):
        self.provision()
        STORE.unlink()
        restored = self.credential('restore')
        self.assertEqual(restored.returncode, 0, restored.stdout)
        self.assertIn('is gone', restored.stdout)
        self.assertEqual(self.shadow_password(), '*')
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertEqual(self.stored(), self.kept('*'))

    def test_unusable_store_after_a_sync_fails_closed(self):
        legacy = subprocess.check_output(
            ['perl', '-e', 'print crypt("wendy", q{$6$5ixFr0sKRtsKKKhY$})'], text=True)
        for content in ('garbage\n', entry('') + 'token\n', entry(legacy) + 'token\n',
                        entry('$6$ab cd') + 'token\n'):
            with self.subTest(content=content):
                self.provision()
                STORE.write_text(content)
                self.assertEqual(self.credential('restore').returncode, 0)
                self.assertEqual(self.shadow_password(), '*')

    def test_unusable_store_on_a_fresh_slot_is_ignored(self):
        STORE.parent.mkdir(parents=True)
        self.new_slot()
        for content in ('', '\n', 'x:y\n', '-o\n', GOOD + '\n',
                        entry(GOOD).replace('wendy:', 'root:'),
                        entry(''), entry('$6$ab cd'), entry(GOOD, last='x'),
                        entry(GOOD, expire='-1'),
                        f'wendy:{GOOD}:19000:0:99999:7:::\n',
                        f'wendy:{GOOD}:19000:::::1:reserved\n',
                        f'wendy:{GOOD}:19000:::::\n',
                        f'wendy:{GOOD}:19000:::::::\n'):
            with self.subTest(content=content):
                SYNCED.unlink(missing_ok=True)
                STORE.write_text(content)
                restored = self.credential('restore')
                self.assertEqual(restored.returncode, 0)
                self.assertIn('not a saved wendy entry', restored.stdout)
                self.assertEqual(self.shadow_password(), '*')
                self.assertEqual(self.shadow_fields()[2], '20000')

    def test_store_from_the_previous_version_is_used_and_upgraded(self):
        STORE.parent.mkdir(parents=True)
        STORE.write_text(entry(GOOD))
        self.new_slot()
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), GOOD)
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertRegex(self.token(), r'^[0-9a-f-]{36}$')

    def test_unkeepable_passwords_are_stored_as_none(self):
        self.provision()
        legacy = subprocess.check_output(
            ['perl', '-e', 'print crypt("wendy", q{$6$5ixFr0sKRtsKKKhY$})'], text=True)
        for bad in ('!!' + GOOD, '$1$saltsalt$' + 'a' * 22, 'x', '!!', '$6$short$abc',
                    legacy, '!' + legacy):
            with self.subTest(bad=bad):
                subprocess.run(['usermod', '-p', bad, 'wendy'], check=True)
                self.assertEqual(self.credential('save').returncode, 0)
                self.assertEqual(self.stored(), self.kept('*'))
                # This slot keeps what was set, and the next boot is unblocked.
                self.assertEqual(self.credential('restore').returncode, 0)
                self.assertEqual(self.shadow_password(), bad)
        subprocess.run(['passwd', '-d', 'wendy'], check=True, capture_output=True)
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertEqual(self.stored(), self.kept('*'))
        for good in ('!' + GOOD, '!*', '!', '$y$j9T$' + 'a' * 22 + '$' + 'b' * 43,
                     '$5$rounds=5000$salt$' + 'c' * 43):
            with self.subTest(good=good):
                subprocess.run(['usermod', '-p', good, 'wendy'], check=True)
                self.assertEqual(self.credential('save').returncode, 0)
                self.assertEqual(self.stored(), self.kept())

    def test_rollback_does_not_bring_back_a_removed_password(self):
        self.provision()
        slot_a = self.slot()
        subprocess.run(['passwd', '-d', 'wendy'], check=True, capture_output=True)
        self.assertEqual(self.credential('save').returncode, 0)
        self.boot(slot_a)
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), '*')

    def test_failed_save_keeps_this_slot_and_closes_the_others(self):
        self.provision()
        slot_a = self.slot()
        # Slot B locks the account, but /data is full.
        subprocess.run(['passwd', '-l', 'wendy'], check=True, capture_output=True)
        locked = self.shadow_password()
        path = self.stub(sync='case "$1" in /data/*.tmp) exit 1 ;; esac')
        failed = self.credential('save', PATH=path)
        self.assertNotEqual(failed.returncode, 0, failed.stdout)
        self.assertFalse(STORE.exists())
        slot_b = self.slot()
        mark = slot_b[1].split()[1]
        self.assertRegex(mark, r'^removed\.[0-9a-f-]{36}$')
        self.assertTrue((STORE.parent / f'wendy.{mark}').exists())
        self.assertEqual((STORE.parent / f'wendy.{mark}').stat().st_size, 0)
        # Rolled back to A before B could save: A keeps no password.
        self.boot(slot_a)
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), '*')
        # B keeps its lock and saves it once there is space again.
        self.boot(slot_b)
        restored = self.credential('restore')
        self.assertEqual(restored.returncode, 0, restored.stdout)
        self.assertEqual(self.shadow_password(), locked)
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertEqual(self.stored(), self.kept())
        # The saved entry replaces the removal marker.
        self.assertEqual(list(STORE.parent.glob('wendy.removed.*')), [])

    def test_an_old_removal_does_not_count_after_a_later_save(self):
        self.provision()
        # Slot A cannot save a new password and removes the store.
        subprocess.run(['usermod', '-p', GOOD, 'wendy'], check=True)
        path = self.stub(sync='case "$1" in /data/*.tmp) exit 1 ;; esac')
        self.assertNotEqual(self.credential('save', PATH=path).returncode, 0)
        slot_a = self.slot()
        # Slot B fails closed, then the operator provisions a newer password.
        self.new_slot()
        SYNCED.write_text('0' * 64 + ' some-old-token\n')
        self.assertEqual(self.credential('restore').returncode, 0)
        newest = self.provision()
        # The store is lost again (a wipe, or another failed save).
        STORE.unlink()
        # Rolled back to A: its old removal no longer counts.
        self.boot(slot_a)
        restored = self.credential('restore')
        self.assertEqual(restored.returncode, 0, restored.stdout)
        self.assertIn('is gone', restored.stdout)
        self.assertEqual(self.shadow_password(), '*')
        self.assertNotEqual(newest, GOOD)

    def test_a_later_failed_save_elsewhere_voids_an_older_removal(self):
        self.provision()
        full = self.stub(sync='case "$1" in /data/*.tmp) exit 1 ;; esac')
        # Slot A cannot save a new password and leaves its marker.
        subprocess.run(['usermod', '-p', GOOD, 'wendy'], check=True)
        self.assertNotEqual(self.credential('save', PATH=full).returncode, 0)
        slot_a = self.slot()
        # Slot B, which saved before, fails closed; /data is still full, and
        # the operator then locks the account on B, which cannot be saved.
        self.new_slot()
        SYNCED.write_text('0' * 64 + ' some-old-token\n')
        self.assertEqual(self.credential('restore').returncode, 0)
        self.assertEqual(self.shadow_password(), '*')
        self.assertNotEqual(self.credential('save', PATH=full).returncode, 0)
        subprocess.run(['passwd', '-l', 'wendy'], check=True, capture_output=True)
        self.assertNotEqual(self.credential('save', PATH=full).returncode, 0)
        self.assertEqual(len(list(STORE.parent.glob('wendy.removed.*'))), 1)
        # Rolled back to A: B's later removal voids A's, so A keeps no password.
        self.boot(slot_a)
        restored = self.credential('restore')
        self.assertEqual(restored.returncode, 0, restored.stdout)
        self.assertIn('is gone', restored.stdout)
        self.assertEqual(self.shadow_password(), '*')

    def watch(self, path=None):
        env = {**os.environ, 'WENDYOS_CREDENTIAL_INTERVAL': '0.2'}
        if path:
            env['PATH'] = path
        watcher = subprocess.Popen(['/test/wendyos-user-credential.sh', 'watch'], env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(watcher.wait, 10)
        self.addCleanup(watcher.kill)

    def wait_stored(self, want, seconds=15):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if STORE.exists() and self.stored() == want:
                return True
            time.sleep(0.2)
        return False

    def test_watcher_never_misses_a_change(self):
        self.provision()
        # Every save takes over a second, so changes land in the middle of one.
        self.watch(self.stub(sync='case "$1" in /data/*) sleep 0.6 ;; esac'))
        for n, gap in enumerate((0, 0.1, 0.5, 0.9)):
            with self.subTest(gap=gap):
                subprocess.run(['usermod', '--expiredate', '1', 'wendy'], check=True)
                time.sleep(0.5 + gap)
                # Each pair ends on a value the store has not held yet.
                subprocess.run(['usermod', '--expiredate', str(30000 + n), 'wendy'], check=True)
                self.assertTrue(self.wait_stored(self.kept()), STORE.read_text())
        # The watcher does not hold the lock between saves.
        started = time.monotonic()
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertLess(time.monotonic() - started, 5)

    def test_watcher_retries_a_failed_save(self):
        self.provision()
        # /data is full until the flag goes away.
        flag = pathlib.Path('/tmp/full')
        flag.touch()
        self.addCleanup(flag.unlink, missing_ok=True)
        self.watch(self.stub(sync='[ -e /tmp/full ] && case "$1" in /data/*.tmp) exit 1 ;; esac'))
        # Let the watcher's start-up save run first, so it cannot pass for a retry.
        time.sleep(1)
        subprocess.run(['passwd', '-l', 'wendy'], check=True, capture_output=True)
        deadline = time.monotonic() + 10
        while STORE.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertFalse(STORE.exists())
        time.sleep(1)
        # Space comes back with no further account change: the save is retried.
        flag.unlink()
        self.assertTrue(self.wait_stored(self.kept(), 20))
        deadline = time.monotonic() + 5
        while list(STORE.parent.glob('wendy.removed.*')) and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertEqual(list(STORE.parent.glob('wendy.removed.*')), [])

    def test_restore_passes_the_entry_on_stdin(self):
        provisioned = self.provision()
        path = self.stub(chpasswd='echo "$0 $*" >> /tmp/argv',
                         chage='echo "$0 $*" >> /tmp/argv')
        self.addCleanup(pathlib.Path('/tmp/argv').unlink, missing_ok=True)
        self.new_slot()
        self.assertEqual(self.credential('restore', PATH=path).returncode, 0)
        self.assertEqual(self.shadow_password(), provisioned)
        argv = pathlib.Path('/tmp/argv').read_text()
        self.assertIn('chpasswd -e', argv)
        self.assertNotIn('$6$', argv)

    def test_restore_that_stops_halfway_fails_closed_and_is_retried(self):
        provisioned = self.provision()
        for step, tool in (
                ('password', {'chpasswd': 'exit 1'}),
                ('last step', {'chage': '[ -e /tmp/stub/once ] && exit 1; touch /tmp/stub/once'})):
            with self.subTest(failing=step):
                # A rolled-back slot, enabled; a later slot saved it disabled.
                subprocess.run(['usermod', '-p', GOOD, '-e', '', 'wendy'], check=True)
                self.other_slot_saves(entry(provisioned, expire='1'))
                failed = self.credential('restore', PATH=self.stub(**tool))
                self.assertNotEqual(failed.returncode, 0, failed.stdout)
                self.assertIn('stays disabled', failed.stdout)
                self.assertEqual(self.shadow_fields()[7], '1')
                self.assertFalse(SYNCED.exists())
                retried = self.credential('restore')
                self.assertEqual(retried.returncode, 0, retried.stdout)
                self.assertEqual(self.shadow_password(), provisioned)
                self.assertEqual(self.shadow_fields()[7], '1')

    def test_restore_that_cannot_disable_changes_nothing(self):
        self.provision()
        self.other_slot_saves(entry('!' + GOOD, expire='1'))
        subprocess.run(['usermod', '-p', GOOD, 'wendy'], check=True)
        failed = self.credential('restore', PATH=self.stub(chage='exit 1'))
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('leaving it as it is', failed.stdout)
        self.assertEqual(self.shadow_password(), GOOD)

    def test_leftover_temporary_file_does_not_widen_the_mode(self):
        STORE.parent.mkdir(parents=True)
        leftover = STORE.parent / 'wendy.tmp'
        leftover.write_text('stale\n')
        leftover.chmod(0o644)
        self.assertEqual(self.credential('save').returncode, 0)
        self.assertEqual(STORE.stat().st_mode & 0o777, 0o600)
        self.assertEqual(SYNCED.stat().st_mode & 0o777, 0o600)

    def test_store_that_cannot_be_written_is_removed(self):
        self.provision()
        subprocess.run(['passwd', '-l', 'wendy'], check=True, capture_output=True)
        (STORE.parent / 'wendy.tmp').mkdir()
        self.addCleanup(shutil.rmtree, STORE.parent / 'wendy.tmp', ignore_errors=True)
        self.assertNotEqual(self.credential('save').returncode, 0)
        self.assertFalse(STORE.exists())

    def test_restore_leaves_other_accounts_alone(self):
        self.provision()
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
