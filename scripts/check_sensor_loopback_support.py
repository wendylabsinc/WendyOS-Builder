#!/usr/bin/env python3
"""Verify SensorLink loopback drivers in the completed image."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from check_mesh_kernel_support import read_config, validate as validate_kernel


def validate(config: dict[str, str], rootfs: Path, release: str) -> list[str]:
    errors = []
    if config.get('CONFIG_SND_ALOOP') != 'm':
        errors.append('CONFIG_SND_ALOOP must be modular for the required package and on-demand loading')
    errors.extend(validate_kernel(config, rootfs, release, [], {
        'CONFIG_VIDEO_DEV': 'videodev',
        'CONFIG_VIDEOBUF2_VMALLOC': 'videobuf2_vmalloc',
        'CONFIG_SND_ALOOP': 'snd_aloop',
    }, external_modules=['v4l2loopback']))
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--rootfs', type=Path, required=True)
    parser.add_argument('--kernel-release', required=True)
    args = parser.parse_args(argv)
    try:
        errors = validate(read_config(args.config), args.rootfs, args.kernel_release)
    except (OSError, ValueError) as error:
        errors = [str(error)]
    for error in errors:
        print(f'SensorLink loopback support error: {error}', file=sys.stderr)
    if errors:
        return 1
    print(f'SensorLink loopback support OK: {args.kernel_release} in {args.rootfs}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
