#!/usr/bin/env python3
"""Mark FAT volumes in a build-time WIC image without mounting them.

Run before compression and block-map generation. Requires native sfdisk and
mtools. Only regular build artifacts are accepted; never use on a device.
"""
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

MARKER = ".metadata_never_index"


def fat_offsets(image, table):
    """Validate all partition bounds before returning FAT byte offsets."""
    size = image.stat().st_size
    sector = table["sectorsize"]
    if sector not in (512, 1024, 2048, 4096) or table.get("unit") != "sectors":
        raise ValueError("unsupported partition sector units")
    offsets = []
    with image.open("rb") as src:
        for part in table["partitions"]:
            start, length = part["start"] * sector, part["size"] * sector
            if start < sector or length < 512 or start + length > size:
                raise ValueError("partition outside image")
            src.seek(start)
            boot = src.read(512)
            if boot[510:512] != b"\x55\xaa":
                continue
            if boot[54:62] not in (b"FAT12   ", b"FAT16   ") and boot[82:90] != b"FAT32   ":
                continue
            offsets.append(start)
    return offsets


def mark_image(image):
    image = pathlib.Path(image)
    if not stat.S_ISREG(image.stat().st_mode):
        raise ValueError("only regular image files are allowed")
    table = json.loads(subprocess.check_output(["sfdisk", "--json", str(image)]))["partitiontable"]
    offsets = fat_offsets(image, table)
    with tempfile.TemporaryDirectory() as tmp:
        marker = pathlib.Path(tmp) / MARKER
        marker.touch()
        if "SOURCE_DATE_EPOCH" in os.environ:
            epoch = int(os.environ["SOURCE_DATE_EPOCH"])
            os.utime(marker, (epoch, epoch))
        for offset in offsets:
            target = f"{image}@@{offset}"
            # Replace only the reserved empty sentinel for idempotence. All
            # other files are preserved, with no mounts or loop devices.
            subprocess.run(["mcopy", "-m", "-o", "-i", target, str(marker), f"::/{MARKER}"], check=True)
            subprocess.run(["mdir", "-i", target, f"::/{MARKER}"], check=True)
    return len(offsets)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} <image.wic>")
    print(f"Marked {mark_image(sys.argv[1])} FAT volumes to disable Spotlight")
