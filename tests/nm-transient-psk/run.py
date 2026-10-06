#!/usr/bin/env python3
"""Compile exact NM callbacks and check recovery plus unchanged control cases."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import shlex
import shutil
import subprocess
import sys
import urllib.request

REVISION = '56b51b98fbb8627c4c09a483702e18fd8aee7ce1'
SOURCE = Path('src/core/devices/wifi/nm-device-wifi.c')
SHA256 = 'e83faed72137306c842411d1a28bce9618932d1648c8493b895df3e110b4455b'
HERE = Path(__file__).resolve().parent


def fail(message):
    sys.exit('ERROR: ' + message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source_args = parser.add_mutually_exclusive_group(required=True)
    source_args.add_argument('--upstream', type=Path, help='Pristine NM 1.56.0 source tree')
    source_args.add_argument('--fetch-upstream', action='store_true', help='Download only the pinned C file')
    parser.add_argument('--output', type=Path, required=True, help='New directory for evidence')
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if args.fetch_upstream:
        source = args.output / 'upstream' / SOURCE
        source.parent.mkdir(parents=True)
        url = f'https://raw.githubusercontent.com/NetworkManager/NetworkManager/{REVISION}/{SOURCE}'
        with urllib.request.urlopen(url, timeout=60) as response:
            source.write_bytes(response.read())
    else:
        source = args.upstream.resolve() / SOURCE
    if hashlib.sha256(source.read_bytes()).hexdigest() != SHA256:
        fail(f'{source}: requires exact NM 1.56.0 source at {REVISION} (SHA256 {SHA256})')

    patch = HERE.parents[1] / 'recipes-connectivity/networkmanager/files/0001-wifi-bound-transient-stored-key-timeout.patch'
    patched = args.output / 'patched'
    target = patched / SOURCE
    target.parent.mkdir(parents=True)
    shutil.copy2(source, target)
    process = subprocess.run(['patch', '--batch', '-p1', '-i', str(patch)], cwd=patched,
                             text=True, capture_output=True)
    (args.output / 'patch.log').write_text(process.stdout + process.stderr)
    if process.returncode:
        fail(f'patch failed; see {args.output / "patch.log"}')
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gobject-2.0'], text=True))
    results = {}
    for label, path in [('baseline', source), ('candidate', target)]:
        out = args.output / label
        out.mkdir()
        subprocess.run([sys.executable, str(HERE / 'extract.py'), str(path), str(out)], check=True)
        binary = out / 'harness'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                        '-Wno-unused-function', '-g', '-I' + str(out), str(HERE / 'harness.c'),
                        *flags, '-o', str(binary)], check=True)
        listing = subprocess.check_output([str(binary), '-l'], text=True)
        cases = [line.removeprefix('# ') for line in listing.splitlines()
                 if line.removeprefix('# ').startswith('/')]
        if len(cases) != 12:
            fail(f'{label}: expected 12 test groups, got {cases}')
        results[label] = {'source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'cases': {}}
        for case in cases:
            result = subprocess.run([str(binary), '-p', case], capture_output=True, text=True)
            log = out / (case[1:].replace('/', '-') + '.log')
            log.write_text(result.stdout + result.stderr)
            # Recovery groups expose missing upstream policy; controls must pass
            # on BOTH sources, so an arbitrary crash cannot be a valid baseline.
            expected_failure = label == 'baseline' and case.startswith('/recovery/')
            if expected_failure:
                ok = result.returncode == -6 and 'ERROR:' in result.stderr and 'harness.c:' in result.stderr
            else:
                ok = result.returncode == 0 and f'ok 1 {case}' in result.stdout
            if not ok:
                fail(f'{label} {case}: unexpected exit {result.returncode}; see {log}\n{result.stderr}')
            results[label]['cases'][case] = result.returncode
        print(f'PASS: {label}, {len(cases)} groups', flush=True)
    (args.output / 'RESULT.json').write_text(json.dumps(results, indent=2) + '\n')
    print('PASS: six baseline regressions, six unchanged controls, all 12 candidate groups')


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(str(error))
