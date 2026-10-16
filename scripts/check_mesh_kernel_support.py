#!/usr/bin/env python3
"""Check effective mesh kernel features and their installed module dependency closure."""

from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import re
import sys


def read_config(path: Path) -> dict[str, str]:
    return dict(re.findall(r"^(CONFIG_[A-Z0-9_]+)=([ym])$", path.read_text(), re.MULTILINE))


def module_contract(entries: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for entry in entries:
        symbol, sep, module = entry.partition(":")
        if not sep or not re.fullmatch(r"CONFIG_[A-Z0-9_]+", symbol) or not re.fullmatch(r"[A-Za-z0-9_-]+", module):
            raise ValueError(f"invalid kernel contract entry: {entry!r}")
        if symbol in result and result[symbol] != module:
            raise ValueError(f"conflicting kernel contract for {symbol}")
        result[symbol] = module
    if not result:
        raise ValueError("empty mesh module contract")
    return result


def _module_name(path: str) -> str | None:
    match = re.fullmatch(r"(.+)\.ko(?:\.(?:xz|gz|zst))?", PurePosixPath(path).name)
    return match.group(1).replace("-", "_") if match else None


def _safe_module_path(path: str) -> bool:
    p = PurePosixPath(path)
    return not p.is_absolute() and ".." not in p.parts and _module_name(path) is not None


def validate(config: dict[str, str], rootfs: Path, release: str,
             builtin: list[str], modules: dict[str, str]) -> list[str]:
    errors: list[str] = []
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+", release) or release in {".", ".."}:
        return [f"invalid kernel release: {release!r}"]
    for symbol in builtin:
        if config.get(symbol) != "y":
            errors.append(f"{symbol} must be built in (effective value: {config.get(symbol, 'unset')})")
    needed: dict[str, str] = {}
    for symbol, module in modules.items():
        state = config.get(symbol)
        if state not in {"y", "m"}:
            errors.append(f"{symbol} is not enabled (effective value: {state or 'unset'})")
        elif state == "m":
            needed[symbol] = module.replace("-", "_")
    if not needed:
        return errors

    # Check only this kernel release. A stale module tree cannot satisfy the image.
    # Try both usrmerge and traditional layouts, refusing paths escaping rootfs.
    rootfs = rootfs.resolve()
    candidates = [rootfs / base / release for base in ("usr/lib/modules", "lib/modules")]
    module_dir = next((p.resolve() for p in candidates
                       if p.is_dir() and p.resolve().is_relative_to(rootfs)), None)
    if module_dir is None:
        return errors + [f"missing installed module directory for kernel {release}"]
    depfile = module_dir / "modules.dep"
    if not depfile.is_file():
        return errors + [f"missing {depfile}; run the image gate after depmod"]

    dependencies: dict[str, list[str]] = {}
    names: dict[str, list[str]] = {}
    for line in depfile.read_text().splitlines():
        if not line.strip():
            continue
        path, sep, deps = line.partition(":")
        paths = [path, *deps.split()]
        if not sep or any(not _safe_module_path(p) for p in paths):
            errors.append(f"invalid modules.dep entry: {line!r}")
            continue
        if path in dependencies:
            errors.append(f"duplicate modules.dep entry: {path}")
        dependencies[path] = deps.split()
        names.setdefault(_module_name(path), []).append(path)

    visited: set[str] = set()

    def check_file(path: str, owner: str) -> None:
        if path in visited:
            return
        visited.add(path)
        file = module_dir / path
        if not file.resolve().is_relative_to(module_dir) or not file.is_file() or file.stat().st_size == 0:
            errors.append(f"{owner} requires missing or invalid module file {path}")
        if path not in dependencies:
            errors.append(f"{owner} requires {path}, absent from modules.dep")
            return
        for dep in dependencies[path]:
            check_file(dep, path)

    for symbol, name in sorted(needed.items()):
        matches = names.get(name, [])
        if len(matches) != 1:
            errors.append(f"{symbol}=m requires exactly one installed {name}.ko (found {len(matches)})")
            continue
        check_file(matches[0], symbol)
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--kernel-release", required=True)
    parser.add_argument("--builtin", action="append", default=[])
    parser.add_argument("--module", action="append", default=[])
    args = parser.parse_args(argv)
    try:
        errors = validate(read_config(args.config), args.rootfs, args.kernel_release,
                          args.builtin, module_contract(args.module))
    except (OSError, ValueError) as error:
        errors = [str(error)]
    for error in errors:
        print(f"mesh kernel support error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"mesh kernel support OK: {args.kernel_release} in {args.rootfs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
