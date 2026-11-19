#!/usr/bin/env python3
"""Validate the selected USG notice profile in an assembled image."""
import argparse
from collections import deque
import os
from pathlib import Path
import re
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


# A Match block overrides the header for the connections it selects.
MATCH_PROTECTED = {'authenticationmethods', 'pubkeyauthentication', 'passwordauthentication',
                   'kbdinteractiveauthentication', 'challengeresponseauthentication'}
AUTOLOGIN_CREDENTIALS = ('agetty.autologin', 'login.noauth')
CREDENTIAL_STORES = ('usr/lib/credstore', 'usr/lib/credstore.encrypted',
                     'etc/credstore', 'etc/credstore.encrypted')
UNIT_DIRS = ('usr/lib/systemd/system', 'lib/systemd/system', 'etc/systemd/system')


def check_no_autologin(root):
    """The account check refuses a login without consent, so an autologin
    console would only loop on a denied login."""
    for store in CREDENTIAL_STORES:
        directory = root / store
        if not directory.is_dir() or directory.is_symlink():
            continue
        for entry in directory.iterdir():
            if any(entry.name == name or entry.name.endswith('.' + name)
                   for name in AUTOLOGIN_CREDENTIALS):
                raise ValueError('USG notice profile cannot be combined with a console '
                                 'autologin: ' + str(entry))
    for units in UNIT_DIRS:
        directory = root / units
        if not directory.is_dir() or directory.is_symlink():
            continue
        for unit in directory.rglob('*'):
            if 'getty' not in str(unit.relative_to(directory)) or unit.is_symlink() \
                    or not unit.is_file():
                continue
            if '--autologin' in unit.read_text(errors='replace'):
                raise ValueError('USG notice profile cannot be combined with a console '
                                 'autologin: ' + str(unit))


def check_ssh_overrides(root, sysconf):
    """The header wins over later global values, but not over these."""
    files = [image_path(root, sysconf / 'ssh' / name)
             for name in ('sshd_config', 'sshd_config_readonly')]
    dropins = sysconf / 'ssh' / 'sshd_config.d'
    if dropins.is_dir() and not dropins.is_symlink():
        files += sorted(path for path in dropins.iterdir() if path.name.endswith('.conf'))
    for path in files:
        if not path.is_file():
            continue
        in_match = False
        for line in path.read_text(errors='replace').splitlines():
            words = line.strip().replace('=', ' ', 1).split()
            if not words or words[0].startswith('#'):
                continue
            keyword = words[0].lower()
            if keyword == 'match':
                in_match = True
            elif in_match and keyword in MATCH_PROTECTED:
                raise ValueError('A Match block must not change USG SSH authentication in '
                                 + str(path))
            elif keyword == 'pamservicename' and [w.lower() for w in words[1:]] != ['sshd']:
                raise ValueError('PAMServiceName must stay sshd in ' + str(path))
    defaults = sysconf / 'default' / 'ssh'
    if defaults.is_file() and not defaults.is_symlink():
        for line in defaults.read_text(errors='replace').splitlines():
            name, _, value = line.strip().partition('=')
            if name.strip() == 'SSHD_OPTS' and re.search(r'(^|[\s"\'])-[of]', value):
                raise ValueError('SSHD_OPTS must not override the USG OpenSSH config in '
                                 + str(defaults))


def check(args):
    root = Path(args.rootfs).resolve(strict=True)
    sysconf = image_path(root, root / args.sysconfdir.lstrip('/'))
    banner = image_path(root, root / args.datadir.lstrip('/') / 'wendyos-access-notice/usg-notice')
    module = image_path(root, root / args.base_libdir.lstrip('/') / 'security/pam_wendy_notice.so')
    if not banner.is_file() or not module.is_file():
        raise ValueError('USG notice profile requires its banner and PAM module in the image')
    check_no_autologin(root)
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
        check_ssh_overrides(root, sysconf)
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
