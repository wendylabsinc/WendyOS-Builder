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
            output = '\n'.join('ifname=' + n for n in state['ifaces'])
        elif command == 'nan_status':
            output = 'nan_started=' + str(int(state['started']))
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

    def set_state(self, started=False, fail_start=False):
        (self.root / 'state.json').write_text(json.dumps(dict(
            started=started, fail_start=fail_start,
            ifaces=['wlan0', 'nan0', 'foreign-ndi'], calls=[])))

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


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--mock':
        mock()
    else:
        unittest.main()
