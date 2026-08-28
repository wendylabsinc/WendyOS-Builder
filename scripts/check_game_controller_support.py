#!/usr/bin/env python3
"""Validate effective game-controller kernel config and image contents."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


MODULE_PACKAGES = {
    "CONFIG_INPUT_EVDEV": "kernel-module-evdev",
    "CONFIG_INPUT_JOYDEV": "kernel-module-joydev",
    "CONFIG_HID": "kernel-module-hid",
    "CONFIG_HID_GENERIC": "kernel-module-hid-generic",
    "CONFIG_USB_HID": "kernel-module-usbhid",
    "CONFIG_UHID": "kernel-module-uhid",
    "CONFIG_BT_HIDP": "kernel-module-hidp",
    "CONFIG_JOYSTICK_XPAD": "kernel-module-xpad",
    "CONFIG_HID_MICROSOFT": "kernel-module-hid-microsoft",
}


def read_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"(CONFIG_[A-Z0-9_]+)=(y|m)", line.strip())
        if match:
            values[match.group(1)] = match.group(2)
    return values


def read_manifest_packages(path: Path) -> set[str]:
    packages: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if fields:
            packages.add(fields[0])
    return packages


def manifest_has(packages: set[str], expected: str) -> bool:
    """Accept Yocto's exact RPROVIDE or version-suffixed package name."""

    versioned = re.compile(rf"^{re.escape(expected)}-[0-9].*$")
    return expected in packages or any(versioned.fullmatch(package) for package in packages)


def validate(config: dict[str, str], packages: set[str]) -> list[str]:
    errors: list[str] = []
    for symbol, module_package in MODULE_PACKAGES.items():
        state = config.get(symbol)
        if state not in {"y", "m"}:
            errors.append(f"{symbol} is not enabled (effective value: {state or 'unset'})")
        elif state == "m" and not manifest_has(packages, module_package):
            errors.append(f"{symbol}=m but {module_package} is absent from the image manifest")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path, help="effective kernel .config")
    parser.add_argument("--manifest", required=True, type=Path, help="wendyos-image package manifest")
    args = parser.parse_args(argv)

    errors = validate(read_config(args.config), read_manifest_packages(args.manifest))
    if errors:
        for error in errors:
            print(f"game-controller support error: {error}", file=sys.stderr)
        return 1

    print(f"game-controller support OK: {args.config} + {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
