#!/usr/bin/env python3
"""Fetch checksum-pinned recipe source, apply its patch queue, run NAN regressions."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='use a cached source archive (checksum still verified)')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    recipe = (root / 'wpa-supplicant_2.11.bbappend').read_text()
    version = re.search(r'^PV = "([^"]+)"', recipe, re.M)[1]
    checksum = re.search(r'SRC_URI\[sha256sum\] = "([^"]+)"', recipe)[1]
    files = root / 'wpa-supplicant'
    with tempfile.TemporaryDirectory(prefix='wendyos-nan-') as tmp:
        tmp = Path(tmp)
        archive = args.archive or tmp / 'source.tar.gz'
        if not args.archive:
            with urllib.request.urlopen(f'https://w1.fi/releases/wpa_supplicant-{version}.tar.gz', timeout=60) as response:
                archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
            raise ValueError('supplicant source checksum mismatch')
        with tarfile.open(archive) as tar:
            # Older build containers predate tarfile's extraction filters.
            # Accept only in-tree regular files/directories, never links.
            for member in tar:
                target = (tmp / member.name).resolve()
                if not target.is_relative_to(tmp):
                    raise ValueError('source archive path escapes extraction directory')
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as src, target.open('wb') as dst:
                        shutil.copyfileobj(src, dst)
                    target.chmod(member.mode & 0o777)
                else:
                    raise ValueError(f'unsupported source archive member: {member.name}')
        source = tmp / f'wpa_supplicant-{version}'
        for name in re.findall(r'file://([^\s]+\.patch)', recipe):
            subprocess.run(['patch', '-p1', '--batch', '--fuzz=0', '-i', str(files / name)], cwd=source, check=True)
        for name in ('wendyos-nan.test.sh', 'wendyos-nan-stop.test.sh'):
            subprocess.run(['sh', str(files / name)], check=True)
        subprocess.run(['python3', str(files / 'wendyos-nan-lifecycle.test.py'), '-v'], check=True)
        for name in ('wendyos-nan-parent.test.py', 'wendyos-nan-peer.test.py'):
            subprocess.run(['python3', str(files / name), str(source)], check=True)
        module_runner = files / 'wendyos-nan-module.test.py'
        if module_runner.exists():
            supplicant = source / 'wpa_supplicant'
            config = (supplicant / 'defconfig').read_text()
            config += '\nCONFIG_LIBNL32=y\nCONFIG_NAN_USD=y\nCONFIG_NAN=y\nCONFIG_PASN=y\n'
            (supplicant / '.config').write_text(config)
            subprocess.run(['make', '-j', str(min(os.cpu_count() or 1, 8)),
                            'CONFIG_MODULE_TESTS=y', 'CONFIG_EXT_PASSWORD_TEST=y',
                            'NEED_FIPS186_2_PRF=y', 'wpa_supplicant'], cwd=supplicant, check=True)
            log = tmp / 'module-tests.log'
            try:
                subprocess.run(['python3', str(module_runner), str(supplicant / 'wpa_supplicant'),
                                '--log', str(log)], check=True)
            except subprocess.CalledProcessError:
                if log.exists():
                    print(log.read_text(), flush=True)
                raise


if __name__ == '__main__':
    main()
