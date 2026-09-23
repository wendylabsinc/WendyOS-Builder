#!/usr/bin/env python3
"""Linux-only helper transaction tests; optional WENDYOS_NAN_TEST_HELPER baseline.

The mock serializes individual supplicant commands, but deliberately pauses a
STATUS response after taking its snapshot. This reproduces a stale check across
independent helper processes without requiring random scheduling or real radios.
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest


def wait_for(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() >= deadline:
            raise TimeoutError("mock synchronization deadline")
        time.sleep(0.005)


def mock():
    root = Path(os.environ['MOCK_ROOT'])
    actor = os.environ.get('ACTOR', 'single')
    args = sys.argv[2:]
    if args[0] == '-g':
        args = args[2:]
    elif args[0] == '-p':
        args = args[4:]
    command = args[0] if args else 'events'
    with (root / 'state.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads((root / 'state.json').read_text())
        state['calls'].append([actor, command, *args[1:]])
        if command == 'status':
            if state.get('fail_status'):
                print('mock global status timeout', file=sys.stderr)
                sys.exit(1)
            output = state.get('status_reply', '\n'.join(
                'ifname=' + n + '\nphyname=' + state.get('radios', {}).get(n, 'phy0')
                for n in state['ifaces']))
        elif command == 'nan_status':
            if state.get('fail_nan_status'):
                print('mock NAN status timeout', file=sys.stderr)
                sys.exit(1)
            output = state.get('nan_status_reply', 'nan_started=' + str(int(state['started'])))
        elif command == 'raw' and args[-2:] == ['GET_CAPABILITY', 'nan']:
            name = args[1].removeprefix('IFNAME=')
            output = 'USD NAN' if state.get('capable', {}).get(name, True) else 'USD'
        elif command == 'nan_start':
            if state['started'] or state.get('fail_start'):
                output = 'FAIL'
            else:
                state['started'] = True
                output = 'OK'
        elif command == 'nan_stop':
            state['started'] = False
            output = 'OK'
        elif command == 'interface_add':
            name = args[1]
            output = 'FAIL' if name in state['ifaces'] else 'OK'
            if output == 'OK':
                state['ifaces'].append(name)
                parent = args[10]
                state.setdefault('radios', {})[name] = state.get('radios', {}).get(parent, 'phy0')
        elif command == 'interface_remove':
            name = args[1]
            output = 'FAIL' if name not in state['ifaces'] else 'OK'
            if output == 'OK':
                state['ifaces'].remove(name)
        else:
            output = 'OK'
        (root / 'state.json').write_text(json.dumps(state))
    if actor == 'first' and command in ('nan_start', 'interface_add'):
        (root / 'first-mutated').touch()
    if command == os.environ.get('GATE_COMMAND') and actor in ('first', 'second'):
        marker = root / (actor + '-snapshot')
        if not marker.exists():
            marker.touch()
            if actor == 'first':
                wait_for(lambda: (root / 'release-first').exists())
            else:
                wait_for(lambda: (root / 'first-mutated').exists())
    print(output)


class LifecycleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.children = []
        self.addCleanup(self.stop_children)
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.bind(str(self.root / 'global'))
        self.addCleanup(self.sock.close)
        self.helper = os.environ.get('WENDYOS_NAN_TEST_HELPER', str(Path(__file__).with_name('wendyos-nan')))
        self.env = dict(os.environ, MOCK_ROOT=str(self.root),
                        WENDYOS_NAN_RUNTIME_DIR=str(self.root / 'run'),
                        WENDYOS_NAN_GLOBAL_CTRL=str(self.root / 'global'),
                        WENDYOS_NAN_WPA_CLI=str(self.root / 'wpa_cli'),
                        WENDYOS_NAN_SYSTEMCTL=str(self.root / 'systemctl'),
                        PATH=str(self.root) + ':' + os.environ['PATH'])
        self.write_executable('wpa_cli', '#!/bin/sh\nexec python3 ' + str(Path(__file__).resolve()) + ' --mock "$@"\n')
        self.write_executable('systemctl', '#!/bin/sh\nprintf "%s\\n" "$*" >> "$MOCK_ROOT/systemctl.log"\n')
        # Reports entry before real flock, so the test can release the first
        # caller only after the second has attempted its transaction.
        self.write_executable('flock', '#!/bin/sh\ntouch "$MOCK_ROOT/${ACTOR:-single}-lock-wait"\nexec ' + shutil.which('flock') + ' "$@"\n')
        self.set_state()

    def write_executable(self, name, text):
        p = self.root / name
        p.write_text(text)
        p.chmod(0o755)

    def set_state(self, started=False, fail_start=False, **extra):
        (self.root / 'state.json').write_text(json.dumps(dict(
            started=started, fail_start=fail_start,
            ifaces=['wlan0', 'nan0', 'foreign-ndi'], calls=[], **extra)))

    def replace_state(self, **extra):
        state = self.state()
        state.update(extra)
        (self.root / 'state.json').write_text(json.dumps(state))

    def state(self):
        return json.loads((self.root / 'state.json').read_text())

    def start(self, *args, **env):
        child = subprocess.Popen([self.helper, *args], env=dict(self.env, **env),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        return child

    def stop_children(self):
        for p in self.children:
            if p.poll() is None:
                p.kill()
            p.communicate(timeout=3)

    def succeeds(self, child):
        out, err = child.communicate(timeout=5)
        self.assertEqual(child.returncode, 0, (out, err, self.state()))

    def concurrent(self, command, gate, *args):
        first = self.start(command, *args, ACTOR='first', GATE_COMMAND=gate)
        wait_for(lambda: (self.root / 'first-snapshot').exists())
        second = self.start(command, *args, ACTOR='second', GATE_COMMAND=gate)
        wait_for(lambda: (self.root / 'second-lock-wait').exists() or
                 (self.root / 'second-snapshot').exists())
        (self.root / 'release-first').touch()
        self.succeeds(first)
        self.succeeds(second)

    def test_concurrent_start_is_idempotent_and_does_not_stop_winner(self):
        self.concurrent('start', 'nan_status')
        state = self.state()
        self.assertTrue(state['started'])
        self.assertEqual(state['ifaces'], ['wlan0', 'nan0', 'foreign-ndi'])
        self.assertEqual(sum(c[1] == 'nan_start' for c in state['calls']), 1)
        self.assertFalse(any(c[1] in ('nan_stop', 'interface_remove') for c in state['calls']))
        self.assertNotIn('restart', (self.root / 'systemctl.log').read_text())

    def test_concurrent_create_is_idempotent_and_preserves_siblings(self):
        self.concurrent('ndi-create', 'status', 'app-ndi')
        self.assertEqual(self.state()['ifaces'], ['wlan0', 'nan0', 'foreign-ndi', 'app-ndi'])
        self.assertEqual(sum(c[1] == 'interface_add' for c in self.state()['calls']), 1)

    def test_every_lifecycle_command_waits_but_read_and_session_calls_do_not(self):
        runtime = self.root / 'run'
        runtime.mkdir()
        with (runtime / 'lifecycle.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            pending = []
            for args in [('start',), ('stop',), ('restore-p2p',),
                         ('ndi-create', 'app-ndi'), ('ndi-remove', 'foreign-ndi')]:
                name = args[0]
                pending.append(self.start(*args, ACTOR=name))
                wait_for(lambda: (self.root / (name + '-lock-wait')).exists())
            self.assertEqual(self.state()['calls'], [])
            self.assertFalse((self.root / 'systemctl.log').exists())
            for args in [('status',), ('events',), ('publish', 'service_name=test'),
                         ('ndp-terminate', 'ndp_id=1')]:
                self.succeeds(self.start(*args))
            self.assertTrue(all(p.poll() is None for p in pending))
            # Cancel waiting commands before unlocking; none may mutate state.
            for p in pending:
                p.terminate()
            fcntl.flock(lock, fcntl.LOCK_UN)
        for p in pending:
            p.communicate(timeout=5)

    def test_failed_start_releases_lock_for_next_caller(self):
        self.set_state(fail_start=True)
        failed = self.start('start')
        failed.communicate(timeout=5)
        self.assertNotEqual(failed.returncode, 0)
        self.set_state()
        self.succeeds(self.start('start'))
        self.assertTrue(self.state()['started'])

    def test_lock_timeout_is_bounded_without_touching_supplicant(self):
        runtime = self.root / 'run'
        runtime.mkdir()
        with (runtime / 'lifecycle.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            start = time.monotonic()
            child = self.start('start')
            out, err = child.communicate(timeout=18)
            elapsed = time.monotonic() - start
            self.assertNotEqual(child.returncode, 0, out)
            self.assertIn('Timed out waiting for NAN lifecycle operation', err)
            self.assertGreaterEqual(elapsed, 14)
            self.assertLess(elapsed, 18)
            self.assertEqual(self.state()['calls'], [])
            self.assertFalse((self.root / 'systemctl.log').exists())

    def fails_without_mutation(self, child):
        out, err = child.communicate(timeout=5)
        self.assertNotEqual(child.returncode, 0, (out, err))
        self.assertNotIn('is not present', err)
        mutations = {'nan_start', 'nan_stop', 'interface_add', 'interface_remove'}
        self.assertFalse(any(c[1] in mutations for c in self.state()['calls']))
        return err

    def test_global_query_failure_is_not_absence_or_successful_cleanup(self):
        for failure in [dict(fail_status=True), dict(status_reply='FAIL'),
                        dict(status_reply=''), dict(status_reply='UNKNOWN COMMAND')]:
            for args in [('start',), ('stop',), ('status',),
                         ('ndi-create', 'app-ndi'), ('ndi-remove', 'foreign-ndi')]:
                with self.subTest(failure=failure, command=args):
                    self.set_state(started=True, **failure)
                    self.fails_without_mutation(self.start(*args))
                    self.assertTrue(self.state()['started'])
                    self.assertIn('nan0', self.state()['ifaces'])
                    self.assertIn('foreign-ndi', self.state()['ifaces'])

    def test_bad_nan_query_preserves_an_existing_cluster(self):
        for failure in [dict(fail_nan_status=True), dict(nan_status_reply='FAIL'),
                        dict(nan_status_reply=''), dict(nan_status_reply='nan_started=2')]:
            with self.subTest(failure=failure):
                self.set_state(started=True, **failure)
                self.fails_without_mutation(self.start('start'))
                self.assertTrue(self.state()['started'])
                self.assertIn('nan0', self.state()['ifaces'])

    def test_failed_start_does_not_remove_an_existing_stopped_interface(self):
        self.set_state(fail_start=True)
        failed = self.start('start')
        failed.communicate(timeout=5)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('nan0', self.state()['ifaces'])
        self.assertFalse(any(c[1] in ('nan_stop', 'interface_remove')
                             for c in self.state()['calls']))

    def test_failed_new_start_removes_only_the_new_management_interface(self):
        for failure in [dict(fail_start=True), dict(fail_nan_status=True)]:
            with self.subTest(failure=failure):
                self.set_state(**failure)
                self.replace_state(ifaces=['wlan0', 'foreign-ndi'])
                failed = self.start('start')
                failed.communicate(timeout=5)
                self.assertNotEqual(failed.returncode, 0)
                self.assertEqual(self.state()['ifaces'], ['wlan0', 'foreign-ndi'])
                removed = [c[2] for c in self.state()['calls'] if c[1] == 'interface_remove']
                self.assertEqual(removed, ['nan0'])

    def two_radios(self, capable=True):
        self.set_state()
        self.replace_state(ifaces=['wlan1', 'p2p-dev-wlan1', 'wlan0', 'p2p-dev-wlan0'],
                           radios={'wlan0': 'phy0', 'p2p-dev-wlan0': 'phy0',
                                   'wlan1': 'phy1', 'p2p-dev-wlan1': 'phy1'},
                           capable={'wlan1': capable})

    def test_selects_capable_radio_and_preserves_other_radios_p2p(self):
        self.two_radios(capable=False)
        self.succeeds(self.start('start'))
        state = self.state()
        self.assertIn('p2p-dev-wlan1', state['ifaces'])
        self.assertNotIn('p2p-dev-wlan0', state['ifaces'])
        self.assertEqual(state['radios']['nan0'], 'phy0')
        self.assertEqual((self.root / 'run/p2p-interfaces').read_text(), 'p2p-dev-wlan0\n')
        self.succeeds(self.start('ndi-create', 'app-ndi'))
        state = self.state()
        self.assertEqual(state['radios']['app-ndi'], 'phy0')
        additions = [c for c in state['calls'] if c[1] == 'interface_add']
        self.assertEqual([c[-1] for c in additions], ['wlan0', 'nan0'])

    def test_ambiguous_radios_require_explicit_selection_before_mutation(self):
        self.two_radios()
        err = self.fails_without_mutation(self.start('start'))
        self.assertIn('Multiple NAN radios', err)
        self.assertFalse((self.root / 'run/p2p-interfaces').exists())
        self.succeeds(self.start('start', WENDYOS_NAN_PARENT_IFACE='wlan1'))
        self.assertEqual(self.state()['radios']['nan0'], 'phy1')
        self.assertIn('p2p-dev-wlan0', self.state()['ifaces'])
        self.assertNotIn('p2p-dev-wlan1', self.state()['ifaces'])

    def test_explicit_unsupported_parent_is_rejected_before_mutation(self):
        self.two_radios(capable=False)
        self.fails_without_mutation(self.start('start', WENDYOS_NAN_PARENT_IFACE='wlan1'))

    def test_ndi_creation_requires_management_and_the_same_radio(self):
        self.set_state()
        self.replace_state(ifaces=['wlan0', 'foreign-ndi'])
        missing = self.start('ndi-create', 'app-ndi')
        missing.communicate(timeout=5)
        self.assertNotEqual(missing.returncode, 0)
        self.assertFalse(any(c[1] == 'interface_add' for c in self.state()['calls']))
        self.set_state(radios={'foreign-ndi': 'phy1'})
        mismatch = self.start('ndi-create', 'foreign-ndi')
        mismatch.communicate(timeout=5)
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn('foreign-ndi', self.state()['ifaces'])

    def test_existing_cluster_must_match_an_explicit_parent(self):
        self.set_state(started=True, radios={'wlan0': 'phy1', 'nan0': 'phy0'})
        self.fails_without_mutation(self.start('start', WENDYOS_NAN_PARENT_IFACE='wlan0'))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--mock':
        mock()
    else:
        unittest.main()
