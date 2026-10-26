"""Stage an in-tree module closure from a matching kernel devkit."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


def stage(devkit, manifest, output):
    requested = manifest.get("build", {}).get("modules")
    if not isinstance(requested, list) or not requested or any(
        not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_]+", name)
        for name in requested
    ):
        raise ValueError("kernel-modules build requires a nonempty list of module names")
    root = devkit / "native-modules"
    index = json.loads((root / "index.json").read_text())
    selected = set()

    def copy(name):
        if name in selected:
            return
        entry = index[name]
        filename = entry["file"]
        if Path(filename).name != filename or not filename.endswith(".ko"):
            raise ValueError("unsafe native module filename")
        source = root / filename
        if hashlib.sha256(source.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("native module checksum mismatch: " + name)
        shutil.copy2(source, output / filename)
        selected.add(name)
        for dependency in entry["depends"]:
            copy(dependency)

    output.mkdir(parents=True, exist_ok=True)
    for name in requested:
        copy(name)
    if manifest["build"].get("firmware_from_devkit"):
        firmware = devkit / "native-firmware"
        if not firmware.is_dir():
            raise ValueError("native driver firmware is missing from the devkit")
        shutil.copytree(firmware, output.parent / "firmware")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("devkit", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        stage(args.devkit, json.loads(args.manifest.read_text()), args.output)
    except (ValueError, KeyError, OSError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
