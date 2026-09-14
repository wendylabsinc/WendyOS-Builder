#!/usr/bin/env python3
"""Check whether a driver manifest supports a WendyOS device.

Exit 0 means supported, 1 means intentionally unsupported, and 2 means the
manifest is invalid. Omitting ``devices`` preserves the original every-device
behaviour; new hardware-specific drivers should always declare it.
"""

from __future__ import annotations

import json
import pathlib
import sys


def supported_devices(manifest: object) -> list[str]:
    if not isinstance(manifest, dict):
        raise ValueError("driver manifest must be a JSON object")
    devices = manifest.get("devices", ["all"])
    if not isinstance(devices, list) or not devices:
        raise ValueError("devices must be a non-empty array")
    if any(not isinstance(device, str) or not device for device in devices):
        raise ValueError("devices entries must be non-empty strings")
    if "all" in devices and devices != ["all"]:
        raise ValueError("devices 'all' sentinel must be the only entry")
    if len(devices) != len(set(devices)):
        raise ValueError("devices contains duplicate entries")
    return devices


def supports(manifest: object, device: str) -> bool:
    devices = supported_devices(manifest)
    return devices == ["all"] or device in devices


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <driver.json> <device>", file=sys.stderr)
        return 2
    manifest_path = pathlib.Path(argv[1])
    device = argv[2]
    if not device:
        print("device must not be empty", file=sys.stderr)
        return 2
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        return 0 if supports(manifest, device) else 1
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"{manifest_path}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
