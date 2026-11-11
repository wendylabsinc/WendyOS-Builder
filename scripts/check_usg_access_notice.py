#!/usr/bin/env python3
"""Validate the selected USG notice profile in an assembled image."""
import argparse
from collections import deque
import os
from pathlib import Path
import sys


def image_path(root, path):
    """Resolve absolute image symlinks without following them on the build host."""
    pending = deque(path.relative_to(root).parts)
    current = root
    links = 0
    while pending:
        part = pending.popleft()
        if part == '.':
            continue
        if part == '..':
            if current == root:
                raise ValueError('Image symlink escapes IMAGE_ROOTFS')
            current = current.parent
            continue
        candidate = current / part
        if candidate.is_symlink():
            links += 1
            if links > 40:
                raise ValueError('Image symlink cycle or excessive indirection')
            target = Path(os.readlink(candidate))
            if target.is_absolute():
                current = root
                target = target.relative_to('/')
            pending.extendleft(reversed(target.parts))
        else:
            current = candidate
    return current


def check(args):
    root = Path(args.rootfs).resolve(strict=True)
    sysconf = image_path(root, root / args.sysconfdir.lstrip('/'))
    banner = image_path(root, root / args.datadir.lstrip('/') / 'wendyos-access-notice/usg-notice')
    module = image_path(root, root / args.base_libdir.lstrip('/') / 'security/pam_wendy_notice.so')
    if not banner.is_file() or not module.is_file():
        raise ValueError('USG notice profile requires its banner and PAM module in the image')
    login = image_path(root, root / args.base_bindir.lstrip('/') / 'login')
    if login.name != 'login.shadow' or not login.is_file():
        raise ValueError('USG notice profile requires the PAM-enabled Shadow login alternative')
    expected = ['auth requisite pam_wendy_notice.so', 'account requisite pam_wendy_notice.so']
    for service in ['login'] + (['sshd'] if args.ssh else []):
        path = image_path(root, sysconf / 'pam.d' / service)
        if not path.is_file() or path.read_text().splitlines()[:2] != expected:
            raise ValueError('USG notice must precede every auth/account path in ' + str(path))
    if args.ssh:
        required = ['UsePAM yes', 'PubkeyAuthentication yes', 'PasswordAuthentication no',
                    'KbdInteractiveAuthentication yes',
                    'AuthenticationMethods publickey,keyboard-interactive:pam',
                    'Banner /usr/share/wendyos-access-notice/usg-notice']
        for name in ['sshd_config', 'sshd_config_readonly']:
            path = image_path(root, sysconf / 'ssh' / name)
            if not path.is_file():
                raise ValueError('Missing USG OpenSSH config ' + str(path))
            lines = [s.strip() for s in path.read_text().splitlines()
                     if s.strip() and not s.lstrip().startswith('#')]
            if lines[:len(required)] != required:
                raise ValueError('USG OpenSSH consent settings must be first in ' + str(path))
    if args.dropbear:
        raise ValueError('USG notice profile supports OpenSSH only, not Dropbear')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rootfs', required=True)
    parser.add_argument('--sysconfdir', default='/etc')
    parser.add_argument('--datadir', default='/usr/share')
    parser.add_argument('--base-libdir', default='/lib')
    parser.add_argument('--base-bindir', default='/bin')
    parser.add_argument('--ssh', action='store_true')
    parser.add_argument('--dropbear', action='store_true')
    try:
        check(parser.parse_args())
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    print('USG notice image configuration passed')
