#!/usr/bin/env python3
"""Validate the WendyOS Bluetooth stack: BlueZ floor and, on machines under
the mainline-transport contract, effective kernel config plus the presence
of the mainline driver/firmware packages and the absence of the vendor
driver packages they replace."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


# Every shipping image must carry at least this BlueZ. The blacksail oe-core
# pin ships 5.86; the floor guards against a pin rollback past the HoG/uhid
# reconnect fixes (uhid persistence landed in 5.73, stabilized by 5.7x).
BLUEZ_PACKAGE = "bluez5"
BLUEZ_MIN_VERSION = (5, 80)

# Machines under the full mainline-Bluetooth contract (wendy-bluetooth.inc).
# Matched as a prefix so both storage variants of a devkit are covered.
FULL_PROFILE_MACHINE_PREFIXES = ("jetson-orin-nano-devkit",)

# Symbols the contract requires as y|m; =m additionally requires the module
# package in this exact image.
MODULE_PACKAGES = {
    "CONFIG_BT": "kernel-module-bluetooth",
    "CONFIG_BT_RFCOMM": "kernel-module-rfcomm",
    "CONFIG_BT_HCIBTUSB": "kernel-module-btusb",
    "CONFIG_BT_RTL": "kernel-module-btrtl",
}

# Bool symbols that must resolve =y (they gate behavior inside their parent
# module rather than producing one of their own).
BUILTIN_SYMBOLS = ("CONFIG_BT_BREDR", "CONFIG_BT_LE", "CONFIG_BT_HCIBTUSB_RTL")

REQUIRED_PACKAGES = ("linux-firmware-rtl8822", "rtk-btusb-blacklist")

# The vendor driver this contract replaces. Any of these in the manifest
# means the removal regressed and the vendor module could race btusb for
# the radio. Prefixed and un-prefixed module package names both count
# (KERNEL_MODULE_PACKAGE_PREFIX aliases via RPROVIDES).
FORBIDDEN_PACKAGE_PATTERNS = (
    r"(nv-)?kernel-module-rtk-btusb",
    r"tegra-firmware-rtl8822",
)


def read_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"(CONFIG_[A-Z0-9_]+)=(y|m)", line.strip())
        if match:
            values[match.group(1)] = match.group(2)
    return values


def read_manifest(path: Path) -> dict[str, str]:
    """Map package name -> version ('' when the manifest line has none)."""

    packages: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if fields:
            packages[fields[0]] = fields[2] if len(fields) >= 3 else ""
    return packages


def manifest_has(packages: dict[str, str], expected: str) -> bool:
    """Accept Yocto's exact RPROVIDE or version-suffixed package name."""

    versioned = re.compile(rf"^{re.escape(expected)}-[0-9].*$")
    return expected in packages or any(versioned.fullmatch(package) for package in packages)


def parse_version(version: str) -> tuple[int, ...]:
    numbers = re.match(r"(\d+(?:\.\d+)*)", version)
    if not numbers:
        return ()
    return tuple(int(part) for part in numbers.group(1).split("."))


def validate_bluez(packages: dict[str, str]) -> list[str]:
    if not manifest_has(packages, BLUEZ_PACKAGE):
        return [f"{BLUEZ_PACKAGE} is absent from the image manifest"]
    version = packages.get(BLUEZ_PACKAGE, "")
    parsed = parse_version(version)
    if not parsed:
        return [f"{BLUEZ_PACKAGE} version {version!r} is unparseable"]
    if parsed < BLUEZ_MIN_VERSION:
        floor = ".".join(str(part) for part in BLUEZ_MIN_VERSION)
        return [f"{BLUEZ_PACKAGE} {version} is older than the {floor} floor"]
    return []


def validate_full_profile(config: dict[str, str], packages: dict[str, str]) -> list[str]:
    errors: list[str] = []
    for symbol, module_package in MODULE_PACKAGES.items():
        state = config.get(symbol)
        if state not in {"y", "m"}:
            errors.append(f"{symbol} is not enabled (effective value: {state or 'unset'})")
        elif state == "m" and not manifest_has(packages, module_package):
            errors.append(f"{symbol}=m but {module_package} is absent from the image manifest")
    for symbol in BUILTIN_SYMBOLS:
        if config.get(symbol) != "y":
            errors.append(f"{symbol} must resolve =y (effective value: {config.get(symbol) or 'unset'})")
    for package in REQUIRED_PACKAGES:
        if not manifest_has(packages, package):
            errors.append(f"required package {package} is absent from the image manifest")
    for pattern in FORBIDDEN_PACKAGE_PATTERNS:
        forbidden = re.compile(rf"^{pattern}(-[0-9].*)?$")
        for package in sorted(packages):
            if forbidden.fullmatch(package):
                errors.append(f"vendor package {package} must not be in the image manifest")
    return errors


def machine_has_full_profile(machine: str) -> bool:
    return machine.startswith(FULL_PROFILE_MACHINE_PREFIXES)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--machine", required=True, help="Yocto MACHINE the manifest belongs to")
    parser.add_argument("--manifest", required=True, type=Path, help="wendyos-image package manifest")
    parser.add_argument("--config", type=Path, help="effective kernel .config (required for contract machines)")
    args = parser.parse_args(argv)

    packages = read_manifest(args.manifest)
    errors = validate_bluez(packages)

    if machine_has_full_profile(args.machine):
        if args.config is None:
            errors.append(
                f"machine {args.machine} is under the Bluetooth contract but no "
                "--config was provided (wendyos-bluetooth-<machine>.config missing?)"
            )
        else:
            errors.extend(validate_full_profile(read_config(args.config), packages))

    if errors:
        for error in errors:
            print(f"bluetooth stack error: {error}", file=sys.stderr)
        return 1

    scope = "full contract" if machine_has_full_profile(args.machine) else "bluez floor"
    print(f"bluetooth stack OK ({scope}): {args.machine} + {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
