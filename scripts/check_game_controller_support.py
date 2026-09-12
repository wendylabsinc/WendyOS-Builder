#!/usr/bin/env python3
"""Validate effective game-controller kernel config and image contents."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = REPO_ROOT / "conf/distro/include/game-controller.inc"


class Contract(NamedTuple):
    """Symbols that must be built in, and symbols that may be modules with a package."""

    builtin: frozenset[str]
    modules: dict[str, str]


def _bitbake_list(text: str, name: str) -> list[str]:
    match = re.search(rf'^{name}\s*=\s*"(.*?)"', text, re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError(f"{name} is not defined in the contract")
    return [token for token in match.group(1).split() if token != "\\"]


def load_contract(path: Path = DEFAULT_CONTRACT) -> Contract:
    text = path.read_text(encoding="utf-8")
    modules: dict[str, str] = {}
    for entry in _bitbake_list(text, "WENDYOS_GAME_CONTROLLER_MODULES"):
        symbol, _, package = entry.partition(":")
        modules[symbol] = package
    builtin = frozenset(_bitbake_list(text, "WENDYOS_GAME_CONTROLLER_BUILTIN"))
    if not builtin and not modules:
        raise ValueError(f"{path} defines no symbols; every board would pass unchecked")
    return Contract(builtin=builtin, modules=modules)


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
    """Yocto suffixes module packages with the kernel release, so accept either form."""

    versioned = re.compile(rf"^{re.escape(expected)}-[0-9].*$")
    return expected in packages or any(versioned.fullmatch(package) for package in packages)


def validate(config: dict[str, str], packages: set[str], contract: Contract) -> list[str]:
    errors: list[str] = []
    for symbol in sorted(contract.builtin):
        if config.get(symbol) != "y":
            state = config.get(symbol) or "unset"
            errors.append(f"{symbol} must be built in (effective value: {state})")
    for symbol, module_package in sorted(contract.modules.items()):
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
    parser.add_argument("--contract", default=DEFAULT_CONTRACT, type=Path, help="shared contract .inc")
    args = parser.parse_args(argv)

    errors = validate(
        read_config(args.config),
        read_manifest_packages(args.manifest),
        load_contract(args.contract),
    )
    if errors:
        for error in errors:
            print(f"game-controller support error: {error}", file=sys.stderr)
        return 1

    print(f"game-controller support OK: {args.config} + {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
