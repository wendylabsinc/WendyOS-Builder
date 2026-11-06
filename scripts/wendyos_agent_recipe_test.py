#!/usr/bin/env python3
"""Execute the wendyos-agent installer: a release with the supervisor turns it on, one without builds the image as before."""
import configparser
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'recipes-core/wendyos-agent/wendyos-agent_1.0.bb'
FILES = RECIPE.parent / 'files'
UNITDIR = 'usr/lib/systemd/system'
AGENT_DROPIN = f'{UNITDIR}/wendyos-agent.service.d/10-supervisor.conf'
UPDATER_DROPIN = f'{UNITDIR}/wendyos-agent-updater.service.d/10-supervisor.conf'


def install(test, release_files):
    """Run do_install against an unpacked release holding release_files; return (D, result)."""
    body = re.search(r'^do_install\(\) \{\n(.*?)^\}', RECIPE.read_text(), re.M | re.S)[1]
    tmp = Path(tempfile.mkdtemp())
    test.addCleanup(shutil.rmtree, tmp)
    unpack, dest = tmp / 'unpack', tmp / 'image'
    release = unpack / 'wendy-agent-linux-arm64'
    release.mkdir(parents=True)
    dest.mkdir()
    for name in release_files:
        (release / name).write_text(f'#!/bin/sh\necho {name}\n')
    for unit in FILES.iterdir():
        (unpack / unit.name).write_bytes(unit.read_bytes())
    values = {
        'D': str(dest), 'S': str(unpack), 'UNPACKDIR': str(unpack),
        'systemd_system_unitdir': '/' + UNITDIR, 'sysconfdir': '/etc',
        'WENDYOS_AGENT_VERSION': '2026.11.05-081952',
    }
    # BitBake variables only; the shell keeps its own (${BINARY}).
    script = ('bbfatal() { echo "$*" >&2; exit 1; }\n'
              'bbwarn() { echo "WARNING: $*" >&2; }\n') + re.sub(
        r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', lambda m: values.get(m[1], m[0]), body)
    result = subprocess.run(['sh', '-eu'], input=script, text=True, capture_output=True)
    return dest, result


def assignments(path, section, key):
    """Every value assigned to key in section, in order: systemd resets a list on an empty one."""
    values, current = [], None
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line.startswith('['):
            current = line.strip('[]')
        elif current == section and line.startswith(key + '='):
            values.append(line[len(key) + 1:])
    return values


def section(path, name):
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    parser.read_string(Path(path).read_text())
    return parser[name]


class AgentRecipeTest(unittest.TestCase):
    def test_a_release_with_the_supervisor_turns_it_on(self):
        dest, result = install(self, ['wendy-agent', 'wendy-agent-supervisor'])
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('wendy-agent', 'wendy-agent-supervisor'):
            path = dest / 'opt/wendyos/bin' / name
            self.assertTrue(path.is_file(), name)
            self.assertEqual(path.stat().st_mode & 0o777, 0o755, name)
            self.assertIn(name, path.read_text())
        # The unit itself is main's; the drop-in replaces what it starts.
        self.assertEqual((dest / UNITDIR / 'wendyos-agent.service').read_bytes(),
                         (FILES / 'wendyos-agent.service').read_bytes())
        self.assertEqual(assignments(dest / AGENT_DROPIN, 'Service', 'ExecStart'),
                         ['', '/opt/wendyos/bin/wendy-agent-supervisor'])

    def test_a_release_without_the_supervisor_builds_the_image_as_before(self):
        dest, result = install(self, ['wendy-agent'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no wendy-agent-supervisor', result.stderr)
        self.assertFalse((dest / 'opt/wendyos/bin/wendy-agent-supervisor').exists())
        self.assertFalse((dest / AGENT_DROPIN).parent.exists())
        self.assertFalse((dest / UPDATER_DROPIN).parent.exists())
        self.assertEqual(section(dest / UNITDIR / 'wendyos-agent.service', 'Service')['ExecStart'],
                         '/opt/wendyos/bin/wendy-agent')

    def test_the_updater_hands_releases_to_the_supervisor(self):
        dest, result = install(self, ['wendy-agent', 'wendy-agent-supervisor'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(assignments(dest / UPDATER_DROPIN, 'Service', 'ExecStart'),
                         ['', '/opt/wendyos/bin/wendy-agent-supervisor fetch'])
        # It may write only the inbox, never the image's agent in /opt/wendyos/bin.
        self.assertEqual(assignments(dest / UPDATER_DROPIN, 'Service', 'ReadWritePaths'),
                         ['', '-/data/wendy-agent/agent/inbox'])
        self.assertEqual(section(FILES / 'wendyos-agent-updater.service', 'Service')['ProtectSystem'], 'strict')

    def test_the_updater_stays_enabled(self):
        dest, result = install(self, ['wendy-agent', 'wendy-agent-supervisor'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(RECIPE.read_text(),
                         r'SYSTEMD_SERVICE:\$\{PN\} = "wendyos-agent\.service wendyos-agent-updater\.service wendyos-agent-updater\.timer"\n')
        self.assertFalse((dest / 'etc/systemd/system').exists())

    def test_the_supervisor_starts_after_data_and_is_never_given_up_on(self):
        unit = section(FILES / 'wendyos-agent-supervisor.conf', 'Unit')
        # The supervisor decides when to give up on an agent, not systemd's start limit.
        self.assertEqual(unit['StartLimitIntervalSec'], '0')
        # Ordering only: without /data the supervisor runs the image's agent.
        self.assertIn('data.mount', unit['After'].split())
        self.assertNotIn('Requires', unit)

    def test_the_agent_is_stopped_once_and_logs_as_itself(self):
        service = section(FILES / 'wendyos-agent-supervisor.conf', 'Service')
        # A second SIGTERM from systemd would cut the agent's stop of its apps short.
        self.assertEqual(service['KillMode'], 'mixed')
        self.assertEqual(service['SyslogIdentifier'], 'wendy-agent')

    def test_an_admins_override_still_wins(self):
        # Drop-ins apply in name order across /usr/lib and /etc; `systemctl edit`
        # writes override.conf, which must come after ours.
        for dropin in (AGENT_DROPIN, UPDATER_DROPIN):
            self.assertLess(Path(dropin).name, 'override.conf')

    def test_the_dropins_are_fetched(self):
        recipe = RECIPE.read_text()
        for name in ('wendyos-agent-supervisor.conf', 'wendyos-agent-updater-supervisor.conf'):
            self.assertIn(f'file://{name}', recipe)


if __name__ == '__main__':
    unittest.main()
