"""Resolve a driver's build inputs for a devkit's device identity."""

import argparse
import copy
import json
from pathlib import Path
import re


def resolve(manifest, device):
    if not isinstance(manifest, dict):
        raise ValueError("driver manifest must be an object")
    variants = manifest.get("variants_by_device", {})
    if not isinstance(variants, dict):
        raise ValueError("variants_by_device must map device IDs to objects")
    for name, variant in variants.items():
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            raise ValueError("invalid variant device ID")
        if not isinstance(variant, dict) or set(variant) - {"source", "build", "patches", "firmware"}:
            raise ValueError("variants may override only source, build, patches and firmware")
        if name not in manifest.get("devices", []):
            raise ValueError("variant device must be in the driver's devices list")
    if variants and not device:
        raise ValueError("device ID required for build variants: rebuild the devkit or pass --device")
    devices = manifest.get("devices")
    if device and devices is not None and "all" not in devices and device not in devices:
        raise ValueError("driver does not support device: " + device)
    result = copy.deepcopy(manifest)
    result.update(copy.deepcopy(variants.get(device, {})))
    result.pop("variants_by_device", None)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--device", default="")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        resolved = resolve(json.loads(args.manifest.read_text()), args.device)
    except (ValueError, TypeError) as exc:
        parser.error(str(exc))
    args.output.write_text(json.dumps(resolved, indent=2) + "\n")


if __name__ == "__main__":
    main()
