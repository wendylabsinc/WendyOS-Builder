#!/usr/bin/env python3
"""Reject images that cannot establish the core mesh IPv4 bridge-hook policy."""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

KEY = 'net/bridge/bridge-nf-call-iptables'
POLICY = '90-wendy-mesh.conf'
RULE = '90-wendy-mesh.rules'
DROPIN = '20-mesh-sysctl.conf'


def selected_files(root: Path, directories: list[str], suffix: str) -> dict[str, Path]:
    """systemd/udev basename precedence: /etc before /run before /usr/lib."""
    result = {}
    for directory in directories:
        for path in sorted((root / directory).glob('*' + suffix)):
            result.setdefault(path.name, path)
    return result


def read_file(path: Path, root: Path) -> str:
    # An absolute symlink is image-relative, never a host file. Masking is empty.
    if path.is_symlink():
        target = path.readlink()
        if str(target) == '/dev/null':
            return ''
        path = root / str(target).lstrip('/') if target.is_absolute() else path.parent / target
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f'policy path escapes image: {path}')
    return path.read_text()


def assignments(text: str):
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(('#', ';')):
            continue
        key, separator, value = line.partition('=')
        key = key.strip().removeprefix('-')
        # sysctl.d: first separator determines dot vs slash notation.
        if '.' in key and ('/' not in key or key.index('.') < key.index('/')):
            key = key.translate(str.maketrans('./', '/.'))
        yield key, value.strip() if separator else None


def unit_values(text: str, section: str, key: str) -> list[str]:
    current, values = '', []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('[') and line.endswith(']'):
            current = line[1:-1]
        elif current == section and line.startswith(key + '='):
            value = line.partition('=')[2].strip()
            if not value:
                values.clear()
            else:
                values.extend(value.split())
    return values


def validate(root: Path) -> list[str]:
    errors = []
    configs = selected_files(root, ['etc/sysctl.d', 'run/sysctl.d', 'usr/local/lib/sysctl.d', 'usr/lib/sysctl.d', 'lib/sysctl.d'], '.conf')
    if POLICY not in configs:
        errors.append(f'missing installed {POLICY}')
    value = None
    for name in sorted(configs):
        for key, candidate in assignments(read_file(configs[name], root)):
            if key == KEY:
                value = candidate
    if value != '0':
        errors.append(f'effective {KEY} must be 0 (found {value!r})')

    rules = selected_files(root, ['etc/udev/rules.d', 'run/udev/rules.d', 'usr/local/lib/udev/rules.d', 'usr/lib/udev/rules.d', 'lib/udev/rules.d'], '.rules')
    rule = read_file(rules[RULE], root) if RULE in rules else ''
    active = [line.strip() for line in rule.splitlines() if line.strip() and not line.lstrip().startswith('#')]
    expected = re.compile(r'ACTION=="add", SUBSYSTEM=="module", KERNEL=="br_netfilter", RUN\+="(/(?:usr/)?lib/systemd/systemd-sysctl) --prefix=/net/bridge/bridge-nf-call-iptables"')
    match = expected.fullmatch(active[0]) if len(active) == 1 else None
    if not match:
        errors.append('missing or changed br_netfilter module-add sysctl rule')
    else:
        helper = root / match[1].lstrip('/')
        if not helper.is_file() or not helper.stat().st_mode & 0o111:
            errors.append(f'missing or non-executable udev helper {match[1]}')

    units = selected_files(root, ['etc/systemd/system', 'run/systemd/system', 'usr/lib/systemd/system', 'lib/systemd/system'], '.service')
    for name in ('systemd-sysctl.service', 'systemd-udevd.service', 'wendyos-agent.service'):
        if name not in units or not read_file(units[name], root).strip():
            errors.append(f'missing or masked {name}')
    drops = selected_files(root, ['etc/systemd/system/wendyos-agent.service.d', 'run/systemd/system/wendyos-agent.service.d', 'usr/lib/systemd/system/wendyos-agent.service.d', 'lib/systemd/system/wendyos-agent.service.d'], '.conf')
    text = read_file(units['wendyos-agent.service'], root) if 'wendyos-agent.service' in units else ''
    text += '\n' + '\n'.join(read_file(drops[name], root) for name in sorted(drops))
    if DROPIN not in drops or any('systemd-sysctl.service' not in unit_values(text, 'Unit', key) for key in ('After', 'Wants')):
        errors.append('agent must pull in and start after systemd-sysctl.service')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rootfs', required=True, type=Path)
    args = parser.parse_args()
    try:
        errors = validate(args.rootfs)
    except (OSError, ValueError) as error:
        errors = [str(error)]
    for error in errors:
        print(f'core mesh policy error: {error}', file=sys.stderr)
    if not errors:
        print('core mesh bridge policy OK')
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
