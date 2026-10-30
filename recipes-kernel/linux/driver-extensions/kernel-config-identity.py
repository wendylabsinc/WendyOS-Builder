#!/usr/bin/env python3
"""Include a reproducible resolved-config fingerprint in the kernel release."""

import argparse
import hashlib
import json
from pathlib import Path
import re


def update(config: Path) -> str:
    text = config.read_text()
    options = {}
    for line in text.splitlines():
        enabled = re.fullmatch(r'(CONFIG_[A-Za-z0-9_]+)=(.*)', line)
        disabled = re.fullmatch(r'# (CONFIG_[A-Za-z0-9_]+) is not set', line)
        if enabled or disabled:
            name, value = enabled.groups() if enabled else (disabled[1], 'n')
            if name in options:
                raise ValueError('duplicate resolved config option: ' + name)
            options[name] = value

    prefix = json.loads(options['CONFIG_LOCALVERSION'])
    if not isinstance(prefix, str) or not re.fullmatch(r'[A-Za-z0-9_.+-]*', prefix):
        raise ValueError('CONFIG_LOCALVERSION must be a safe kernel release suffix')
    # Re-running configure must not hash the preceding generated fingerprint.
    prefix = re.sub(r'-cfg[0-9a-f]{16}$', '', prefix)
    options['CONFIG_LOCALVERSION'] = json.dumps(prefix)
    # A signing key's location is incidental. Keep the actual setting intact;
    # enabling/disabling module signing still changes the fingerprint.
    if 'CONFIG_MODULE_SIG_KEY' in options:
        options['CONFIG_MODULE_SIG_KEY'] = '"<module-signing-key>"'
    canonical = ''.join(name + '=' + value + '\n' for name, value in sorted(options.items()))
    digest = hashlib.sha256(('wendyos-kernel-config-v1\n' + canonical).encode()).hexdigest()[:16]
    suffix = prefix + '-cfg' + digest
    updated = re.sub(r'^CONFIG_LOCALVERSION=.*$',
                     lambda match: 'CONFIG_LOCALVERSION=' + json.dumps(suffix), text, flags=re.MULTILINE)
    if updated != text:
        config.write_text(updated)
    return suffix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path)
    args = parser.parse_args()
    try:
        print(update(args.config))
    except (KeyError, OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
