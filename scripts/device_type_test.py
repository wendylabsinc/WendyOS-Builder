#!/usr/bin/env python3
"""Tests for the persisted device identity: device-type and device-uuid.

Three layers, all running the shipped code:
  - the device-type functions, sourced from setup-etc-binds.sh and called with
    fixture paths;
  - the whole of setup-etc-binds.sh against a fake root in a private user and
    mount namespace, so the bind mounts are real and the host is untouched;
  - the recipe's install step and generate-uuid.sh.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'recipes-core/wendyos-identity/wendyos-identity_1.0.bb'
SETUP = ROOT / 'recipes-core/wendyos-etc-binds/files/setup-etc-binds.sh'
UUID_SCRIPT = ROOT / 'recipes-core/wendyos-identity/files/generate-uuid.sh'

IMAGE = 'BOARD=jetson-agx-orin\nMACHINE=jetson-agx-orin-devkit-wendyos\n'
LEGACY = ('BOARD=jetson-agx-orin-emmc\n'
          'MACHINE=jetson-agx-orin-devkit-emmc-wendyos\nSTORAGE=emmc\n')
FOREIGN = 'BOARD=jetson-agx-thor\nMACHINE=jetson-agx-thor-devkit-nvme-wendyos\n'


class Fixture(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)


class DeviceTypeFunctionsTest(Fixture):
    def setUp(self):
        super().setUp()
        self.image = self.root / 'image/device-type'
        self.target = self.root / 'data/device-type'
        self.stage = self.root / 'data/device-type.tmp'
        self.synced = self.root / 'synced'
        self.image.parent.mkdir()
        self.target.parent.mkdir()
        self.image.write_text(IMAGE)

    def call(self, function, *args, overrides=''):
        # sync is recorded, then really run, so a dropped sync is a failure.
        script = f'''
            logger() {{ :; }}
            source "{SETUP}"
            sync() {{ printf '%s\\n' "$@" >> "{self.synced}"; command sync "$@"; }}
            {overrides}
            "$@"
        '''
        return subprocess.run(['bash', '-c', script, 'test', function, *args],
                              text=True, capture_output=True)

    def restore(self, overrides=''):
        return self.call('restore_device_type', str(self.image), str(self.target),
                         overrides=overrides)

    def write_target(self, content):
        if self.target.exists():
            self.target.unlink()
        if content is not None:
            self.target.write_bytes(content.encode())

    def assert_untouched(self, content, before):
        self.assertEqual(self.target.read_bytes(), content.encode())
        after = self.target.stat()
        self.assertEqual((after.st_ino, after.st_mtime_ns, after.st_mode),
                         (before.st_ino, before.st_mtime_ns, before.st_mode))

    def test_sourcing_the_script_runs_nothing(self):
        result = self.call('true')
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))

    def test_board_is_parsed_like_the_updater(self):
        # wendyos-update: lines trimmed, first non-empty BOARD= wins.
        cases = {
            'BOARD=a\n': 'a',
            'BOARD=a': 'a',
            'BOARD=a\r\nMACHINE=m\r\n': 'a',
            '  BOARD=a \n': 'a',
            'MACHINE=m\nBOARD=a\n': 'a',
            'BOARD=\nBOARD=a\n': 'a',
            ' BOARD=first\nBOARD=second\n': 'first',
            'BOARD=a\nBOARD=b\n': 'a',
            '': None,
            '\n': None,
            'BOARD=\n': None,
            'MACHINE=m\n': None,
            'a\n': None,
            'XBOARD=a\n': None,
            'BOARD=a\0b\n': None,
            '\0' * 60: None,
        }
        for content, board in cases.items():
            with self.subTest(content=content):
                self.write_target(content)
                result = self.call('device_type_board', str(self.target))
                if board is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, '')
                else:
                    self.assertEqual((result.returncode, result.stdout), (0, board + '\n'))
        self.write_target(None)
        self.assertNotEqual(self.call('device_type_board', str(self.target)).returncode, 0)

    def test_unusable_metadata_is_restored(self):
        cases = [None, '', '\n', 'BOARD=\n', 'MACHINE=m\n', 'jetson-agx-orin\n',
                 '\0' * 60, 'BOARD=jetson-agx\0-orin\n']
        for content in cases:
            with self.subTest(content=content):
                self.write_target(content)
                result = self.restore()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.target.read_text(), IMAGE)
                self.assertEqual(self.target.stat().st_mode & 0o777, 0o644)
                self.assertFalse(self.stage.exists())

    def test_file_that_differs_from_the_image_is_replaced(self):
        cases = [
            FOREIGN,                       # another board's /data
            LEGACY,                        # an older image of this board
            'BOARD=jetson-agx-or\n',       # cut short
            IMAGE + 'STORAGE=nvme\n',      # same board, a line the image lacks
            IMAGE.replace('\n', '\r\n'),
            IMAGE.rstrip('\n'),
            'BOARD=$(touch executed)\n',
        ]
        for content in cases:
            with self.subTest(content=content):
                self.write_target(content)
                result = self.restore()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.target.read_text(), IMAGE)
                self.assertIn('Device type set to jetson-agx-orin', result.stdout)
                self.assertFalse((self.root / 'executed').exists())
                self.assertFalse(Path('executed').exists())

    def test_file_equal_to_the_image_is_not_rewritten(self):
        self.write_target(IMAGE)
        self.target.chmod(0o640)
        before = self.target.stat()
        result = self.restore()
        self.assertEqual((result.returncode, result.stdout), (0, ''), result.stderr)
        self.assert_untouched(IMAGE, before)
        self.assertFalse(self.synced.exists())

    def test_unusable_image_file_never_replaces_the_target(self):
        for image in (None, '', 'BOARD=\n', 'MACHINE=only\n'):
            for content, usable in ((LEGACY, True), ('broken', False), (None, False)):
                with self.subTest(image=image, content=content):
                    if self.image.exists():
                        self.image.unlink()
                    if image is not None:
                        self.image.write_text(image)
                    self.write_target(content)
                    result = self.restore()
                    self.assertEqual(result.returncode == 0, usable)
                    self.assertIn('missing or names no board', result.stderr)
                    if content is None:
                        self.assertFalse(self.target.exists())
                    else:
                        self.assertEqual(self.target.read_text(), content)

    def test_failed_restore_leaves_the_target_untouched(self):
        failures = [
            'cp() { printf "BOARD=partial" > "$2"; return 1; }',
            # A short copy that reports success must not be renamed into place.
            'cp() { printf "BOARD=jetson-agx" > "$2"; }',
            'chmod() { return 1; }',
            f'sync() {{ printf "%s\\n" "$@" >> "{self.synced}"; return 1; }}',
            'mv() { return 1; }',
        ]
        for override in failures:
            with self.subTest(override=override):
                self.write_target('')
                before = self.target.stat()
                result = self.restore(override)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Failed to restore device type', result.stderr)
                self.assert_untouched('', before)
                self.assertFalse(self.stage.exists())

    def test_restore_is_synced_before_the_rename(self):
        self.write_target('')
        probe = (f'mv() {{ grep -qxF "{self.stage}" "{self.synced}" || return 1; '
                 'command mv "$@"; }')
        result = self.restore(probe)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.synced.read_text().splitlines(),
                         [str(self.stage), str(self.target.parent)])

    def test_stage_left_by_a_power_cut_is_removed(self):
        for content in (IMAGE, ''):
            with self.subTest(content=content):
                self.write_target(content)
                self.stage.write_text('BOARD=half')
                self.assertEqual(self.restore().returncode, 0)
                self.assertEqual(sorted(p.name for p in self.target.parent.iterdir()),
                                 ['device-type'])

    def test_directory_in_place_of_the_file_is_an_error(self):
        self.target.mkdir()
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('is a directory', result.stderr)
        self.assertEqual(list(self.target.iterdir()), [])


# Builds a fake root, enters it and runs the whole script. $1 is the fake root,
# $2 the shell snippet that prepares /data before the script runs.
NAMESPACE_RUN = r'''
set -eu
root=$1
mkdir -p "$root"/{etc/wendyos,etc/wendy-agent,etc/NetworkManager/system-connections}
mkdir -p "$root"/{data,config,proc,dev,tmp,stub,usr/lib/wendyos}
# The host's programs and libraries, read-only, around a fake /usr/lib/wendyos.
for entry in /usr/* /usr/lib/*; do
    [ "$entry" = /usr/lib ] && continue
    if [ -L "$entry" ]; then
        ln -s "$(readlink "$entry")" "$root$entry"
    elif [ -d "$entry" ]; then
        mkdir -p "$root$entry"
        mount --rbind "$entry" "$root$entry"
    fi
done
for link in bin sbin lib lib32 lib64 libx32; do
    if [ -L "/$link" ]; then
        ln -s "$(readlink "/$link")" "$root/$link"
    elif [ -d "/$link" ]; then
        mkdir -p "$root/$link"
        mount --rbind "/$link" "$root/$link"
    fi
done
mount --rbind /dev "$root/dev"
mount -t tmpfs tmpfs "$root/data"
printf '#!/bin/sh\nexit 0\n' > "$root/stub/logger"
chmod +x "$root/stub/logger"
exec chroot "$root" /bin/bash -c '
    export PATH=/stub:/usr/sbin:/usr/bin:/sbin:/bin
    eval "$0"
    rc=0
    /setup-etc-binds.sh > /tmp/log 2>&1 || rc=$?
    eval "$1"
    rc2=0
    if [ -n "$1" ]; then /setup-etc-binds.sh > /tmp/log2 2>&1 || rc2=$?; fi
    binds=""
    for p in /etc/wendyos /etc/NetworkManager/system-connections /etc/wendy-agent; do
        if mountpoint -q "$p"; then binds="${binds}Y"; else binds="${binds}n"; fi
    done
    echo "rc=$rc rc2=$rc2 binds=$binds"
    echo "enrolled=$(cat /etc/wendy-agent/provisioning.json 2>/dev/null)"
    echo "version=$(cat /etc/wendyos/version.txt 2>/dev/null)"
    echo "files=$(ls -A /data/etc/wendyos 2>/dev/null | tr "\n" " ")"
    echo "--device-type--"
    cat /etc/wendyos/device-type 2>/dev/null || true
    echo "--log--"
    cat /tmp/log /tmp/log2 2>/dev/null || true
' "$2" "$3"
'''

D = '/data/etc/wendyos'
ALL_DIRS = (f'mkdir -p {D} /data/etc/NetworkManager/system-connections '
            '/data/etc/wendy-agent; echo yes > /data/etc/wendy-agent/provisioning.json; ')


def namespaces_available():
    try:
        return subprocess.run(['unshare', '-rm', 'true'], capture_output=True).returncode == 0
    except OSError:
        return False


@unittest.skipUnless(namespaces_available(), 'needs unprivileged user namespaces')
class WholeScriptTest(Fixture):
    def boot(self, prepare='', then='', image=IMAGE):
        root = Path(tempfile.mkdtemp(dir=self.root))
        for sub in ('etc/wendyos', 'usr/lib/wendyos'):
            (root / sub).mkdir(parents=True)
        if image is not None:
            (root / 'etc/wendyos/device-type').write_text(image)
        (root / 'usr/lib/wendyos/version.txt').write_text('WendyOS-9.9.9\n')
        (root / 'setup-etc-binds.sh').write_text(SETUP.read_text())
        (root / 'setup-etc-binds.sh').chmod(0o755)
        result = subprocess.run(
            ['unshare', '-rm', 'bash', '-c', NAMESPACE_RUN, 'ns', str(root), prepare, then],
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        head, rest = result.stdout.split('--device-type--\n', 1)
        device_type, log = rest.split('--log--\n', 1)
        state = dict(pair.split('=', 1) for pair in head.split('\n')[0].split())
        for line in head.splitlines()[1:]:
            key, _, value = line.partition('=')
            state[key] = value
        return state, device_type, log

    def test_fresh_data_is_seeded(self):
        state, device_type, log = self.boot()
        self.assertEqual((state['rc'], state['binds']), ('0', 'YYY'), log)
        self.assertEqual(device_type, IMAGE)
        self.assertEqual(state['version'], 'WendyOS-9.9.9')
        self.assertEqual(state['files'].split(), ['device-type', 'version.txt'])

    def test_empty_file_from_an_interrupted_seed_is_repaired(self):
        state, device_type, log = self.boot(f'mkdir -p {D}; : > {D}/device-type')
        self.assertEqual((state['rc'], state['binds']), ('0', 'YYY'), log)
        self.assertEqual(device_type, IMAGE)

    def test_data_from_an_older_image_or_another_board_follows_the_image(self):
        for content in (LEGACY, FOREIGN):
            with self.subTest(content=content):
                state, device_type, log = self.boot(
                    f"mkdir -p {D}; printf '{content}' > {D}/device-type".replace('\n', '\\n'))
                self.assertEqual((state['rc'], device_type), ('0', IMAGE), log)
                self.assertIn('Device type set to jetson-agx-orin', log)

    def test_second_boot_of_the_same_image_writes_nothing(self):
        stamp = f'mkdir -p {D}; printf \'{IMAGE}\' > {D}/device-type; touch -d @1 {D}/device-type'
        state, device_type, log = self.boot(
            stamp.replace('\n', '\\n'), then=f'stat -c mtime=%Y {D}/device-type >> /tmp/log')
        self.assertEqual((state['rc'], device_type), ('0', IMAGE), log)
        self.assertIn('mtime=1\n', log)
        self.assertNotIn('Device type set to', log)

    def test_read_only_data_still_gets_every_bind_and_fails_the_unit(self):
        # The enrollment and Wi-Fi binds must not depend on the identity writes.
        state, device_type, log = self.boot(
            ALL_DIRS + f': > {D}/device-type; mount -o remount,ro /data')
        self.assertEqual(state['binds'], 'YYY', log)
        self.assertEqual(state['enrolled'], 'yes')
        self.assertEqual(state['rc'], '1', log)
        self.assertEqual(device_type, '')
        self.assertIn('Device type remains unusable', log)
        self.assertIn('Failed to refresh /etc/wendyos/version.txt', log)
        self.assertNotIn('All bind mounts successfully configured', log)

    def test_unusable_image_file_fails_the_unit_after_the_binds(self):
        state, device_type, log = self.boot(ALL_DIRS + f': > {D}/device-type', image=None)
        self.assertEqual((state['rc'], state['binds']), ('1', 'YYY'), log)
        self.assertEqual(state['enrolled'], 'yes')
        self.assertNotIn('All bind mounts successfully configured', log)

    def test_restart_with_the_bind_active_leaves_the_file_alone(self):
        # /etc/wendyos/device-type is now the /data copy: it must not be read
        # as the image's file, and a healthy one must not fail the unit.
        state, device_type, log = self.boot(then='true')
        self.assertEqual((state['rc'], state['rc2'], device_type), ('0', '0', IMAGE), log)
        state, device_type, log = self.boot(then=': > /etc/wendyos/device-type')
        self.assertEqual((state['rc'], state['rc2'], state['binds']), ('0', '1', 'YYY'), log)
        self.assertEqual(device_type, '')
        self.assertIn('a reboot restores it', log)


class RecipeInstallTest(Fixture):
    def test_recipe_installs_one_copy_of_the_identity(self):
        recipe = RECIPE.read_text()
        body = re.search(r'^do_install:append\(\) \{\n(.*?)^\}', recipe, re.M | re.S)[1]
        for storage in ('', 'emmc', 'nvme'):
            with self.subTest(storage=storage):
                image = self.root / f'image-{storage}'
                values = {'D': str(image), 'sysconfdir': '/etc', 'STORAGE': storage,
                          'WENDYOS_BOARD_ID': 'jetson-agx-orin',
                          'MACHINE': 'jetson-agx-orin-devkit-wendyos'}
                script = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}',
                                lambda m: values[m[1]], body)
                subprocess.run(['sh', '-eu'], input=script, text=True, check=True)
                expected = IMAGE + (f'STORAGE={storage}\n' if storage else '')
                device_type = image / 'etc/wendyos/device-type'
                self.assertEqual(device_type.read_text(), expected)
                self.assertEqual(device_type.stat().st_mode & 0o777, 0o644)
                # The pre-bind /etc file is the only source the boot script needs.
                self.assertEqual([p.relative_to(image).as_posix()
                                  for p in image.rglob('*') if p.is_file()],
                                 ['etc/wendyos/device-type'])
        self.assertIn('FILES:${PN} += "${sysconfdir}/wendyos/device-type"', recipe)
        self.assertNotIn('${nonarch_libdir}/wendyos/device-type', recipe)


class DeviceUuidTest(Fixture):
    UUID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'

    def generate(self, uuidgen='echo AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE'):
        default = 'UUID_FILE="/etc/wendyos/device-uuid"'
        script = UUID_SCRIPT.read_text()
        self.assertEqual(script.count(default), 1)
        self.uuid = self.root / 'wendyos/device-uuid'
        stubs = self.root / 'stubs'
        stubs.mkdir(exist_ok=True)
        for name, body in (('uuidgen', uuidgen), ('logger', 'exit 0')):
            (stubs / name).write_text(f'#!/bin/sh\n{body}\n')
            (stubs / name).chmod(0o755)
        env = dict(os.environ, PATH=f'{stubs}:{os.environ["PATH"]}')
        return subprocess.run(
            ['bash', '-c', script.replace(default, f'UUID_FILE="{self.uuid}"')],
            text=True, capture_output=True, env=env)

    def test_missing_or_empty_uuid_is_generated(self):
        for content in (None, '', '\n', ' \n', '\0' * 37):
            with self.subTest(content=content):
                result = self.generate()
                if content is not None:
                    self.uuid.write_text(content)
                    result = self.generate()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.uuid.read_text(), self.UUID + '\n')
                self.assertEqual(self.uuid.stat().st_mode & 0o777, 0o644)
                self.assertEqual([p.name for p in self.uuid.parent.iterdir()], ['device-uuid'])
                self.uuid.unlink()

    def test_existing_uuid_is_never_replaced(self):
        self.generate()
        for content in ('11111111-2222-4333-8444-555555555555\n', 'not-a-uuid'):
            with self.subTest(content=content):
                self.uuid.write_text(content)
                before = self.uuid.stat()
                self.assertEqual(self.generate().returncode, 0)
                self.assertEqual(self.uuid.read_text(), content)
                self.assertEqual(self.uuid.stat().st_ino, before.st_ino)

    def test_failed_generation_writes_nothing(self):
        result = self.generate(uuidgen='exit 1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.uuid.parent.iterdir()) if self.uuid.parent.exists() else [], [])


if __name__ == '__main__':
    unittest.main()
