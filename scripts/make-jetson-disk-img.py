#!/usr/bin/env python3
"""Create a raw GPT disk image from a Jetson tegraflash layout.

The r38+ tegraflash bundle no longer ships doexternal.sh/dosdcard.sh. This
implements their offline-only work for the raw artifacts retained behind
``wendy install --rootfs-only``. It never signs or talks to a Jetson.

Requires ``sgdisk`` and, when a layout references Android sparse images,
``simg2img``.
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET

SECTOR_SIZE = 512
ALIGN_SECTORS = 2048
GPT_BACKUP_SECTORS = 33
GPT_MAX_PARTITIONS = 128


def parse_int(value: str | None, label: str) -> int:
    if value is None or not value.strip():
        raise ValueError(f"{label} is missing")
    try:
        return int(value.strip(), 0)
    except ValueError as exc:
        raise ValueError(f"{label} is not an integer: {value!r}") from exc


def child_text(element: ET.Element, name: str, default: str = "") -> str:
    child = element.find(name)
    return (child.text or "").strip() if child is not None else default


def safe_image_path(bundle_dir: pathlib.Path, name: str) -> pathlib.Path:
    relative = pathlib.PurePosixPath(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"unsafe partition filename: {name!r}")
    path = bundle_dir.joinpath(*relative.parts)
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"partition image is missing or not regular: {name}")
    return path


def parse_layout(bundle_dir: pathlib.Path, layout_name: str,
                 device_type: str) -> tuple[int, list[dict]]:
    layout = bundle_dir / layout_name
    tree = ET.parse(layout)
    devices = [device for device in tree.getroot().findall(".//device")
               if device.get("type") == device_type]
    if len(devices) != 1:
        raise ValueError(
            f"expected exactly one <device type={device_type!r}> in {layout}, "
            f"found {len(devices)}"
        )
    device = devices[0]
    sector_size = parse_int(device.get("sector_size", "512"), "sector_size")
    if sector_size != SECTOR_SIZE:
        raise ValueError(f"sector_size {sector_size} is unsupported (want {SECTOR_SIZE})")
    num_sectors = parse_int(device.get("num_sectors"), "num_sectors")
    if num_sectors <= ALIGN_SECTORS + GPT_BACKUP_SECTORS:
        raise ValueError("device geometry is too small for GPT")

    partitions: list[dict] = []
    for element in device.findall("partition"):
        partition_type = element.get("type", "data")
        if partition_type in {
            "protective_master_boot_record", "primary_gpt", "secondary_gpt"
        }:
            continue
        name = (element.get("name") or "").strip()
        if not name:
            raise ValueError("partition without a name")
        if child_text(element, "allocation_policy") != "sequential":
            raise ValueError(f"partition {name} is not sequential")
        size_bytes = parse_int(child_text(element, "size"), f"{name} size")
        if size_bytes <= 0 or size_bytes % sector_size:
            raise ValueError(f"partition {name} size is not positive/sector-aligned")
        filename = child_text(element, "filename")
        if filename:
            source = safe_image_path(bundle_dir, filename)
            if source.stat().st_size > size_bytes and not filename.endswith(".simg"):
                raise ValueError(f"partition image {filename} does not fit in {name}")
        attributes = parse_int(child_text(element, "allocation_attribute", "0"),
                               f"{name} allocation_attribute")
        part_id = element.get("id")
        partitions.append({
            "name": name,
            "id": parse_int(part_id, f"{name} id") if part_id else None,
            "size_bytes": size_bytes,
            "filename": filename or None,
            "type_guid": child_text(element, "partition_type_guid") or None,
            "unique_guid": child_text(element, "unique_guid") or None,
            "fill_to_end": bool(attributes & 0x800),
        })
    if not partitions:
        raise ValueError(f"{device_type} layout has no partitions")
    assign_gpt_numbers(partitions)
    place_partitions(partitions, num_sectors, sector_size)
    return num_sectors, partitions


def assign_gpt_numbers(partitions: list[dict]) -> None:
    used: set[int] = set()
    for partition in partitions:
        number = partition["id"]
        if number is None:
            continue
        if number < 1 or number > GPT_MAX_PARTITIONS or number in used:
            raise ValueError(f"invalid/duplicate GPT partition id {number}")
        used.add(number)
    next_number = 1
    for partition in partitions:
        if partition["id"] is None:
            while next_number in used:
                next_number += 1
            if next_number > GPT_MAX_PARTITIONS:
                raise ValueError("layout has more than 128 GPT partitions")
            partition["id"] = next_number
            used.add(next_number)


def align(value: int) -> int:
    return ((value + ALIGN_SECTORS - 1) // ALIGN_SECTORS) * ALIGN_SECTORS


def place_partitions(partitions: list[dict], num_sectors: int,
                     sector_size: int = SECTOR_SIZE) -> None:
    next_sector = ALIGN_SECTORS
    last_usable = num_sectors - GPT_BACKUP_SECTORS - 1
    for index, partition in enumerate(partitions):
        start = align(next_sector)
        minimum = partition["size_bytes"] // sector_size
        if partition["fill_to_end"]:
            if index != len(partitions) - 1:
                raise ValueError(f"fill-to-end partition {partition['name']} is not last")
            available = last_usable - start + 1
            if available < minimum:
                raise ValueError(f"device is too small for partition {partition['name']}")
            size = available
        else:
            size = minimum
        end = start + size - 1
        if end > last_usable:
            raise ValueError(f"partition {partition['name']} exceeds device capacity")
        partition["_start_lba"] = start
        partition["_end_lba"] = end
        next_sector = end + 1


def concrete_guid(value: str | None) -> str | None:
    if not value:
        return None
    if value.upper() in {"APPUUID", "APPUUID_B"}:
        return None
    parts = value.split("-")
    if [len(part) for part in parts] != [8, 4, 4, 4, 12]:
        raise ValueError(f"invalid GUID {value!r}")
    int("".join(parts), 16)
    return value


def create_gpt(image: pathlib.Path, partitions: list[dict]) -> None:
    command = ["sgdisk", "--clear", "-a", str(ALIGN_SECTORS)]
    for partition in partitions:
        number = partition["id"]
        command.extend([
            f"--new={number}:{partition['_start_lba']}:{partition['_end_lba']}",
            f"--change-name={number}:{partition['name']}",
        ])
        if partition["type_guid"]:
            type_guid = concrete_guid(partition["type_guid"])
            if type_guid is None:
                raise ValueError(f"partition {partition['name']} has a symbolic type GUID")
            command.append(f"--typecode={number}:{type_guid}")
        if (guid := concrete_guid(partition["unique_guid"])):
            command.append(f"--partition-guid={number}:{guid}")
    command.append(str(image))
    subprocess.run(command, check=True)


def dd(source: pathlib.Path, destination: pathlib.Path, byte_offset: int) -> None:
    subprocess.run([
        "dd", f"if={source}", f"of={destination}", "bs=4M",
        "conv=notrunc,sparse", f"seek={byte_offset}", "oflag=seek_bytes",
    ], check=True)


def write_partitions(image: pathlib.Path, partitions: list[dict],
                     bundle_dir: pathlib.Path, sector_size: int = SECTOR_SIZE) -> None:
    for partition in partitions:
        filename = partition["filename"]
        if not filename:
            continue
        source = safe_image_path(bundle_dir, filename)
        converted: pathlib.Path | None = None
        try:
            if filename.endswith(".simg"):
                with tempfile.NamedTemporaryFile(prefix="wendy-simg-", delete=False) as tmp:
                    converted = pathlib.Path(tmp.name)
                subprocess.run(["simg2img", str(source), str(converted)], check=True)
                source = converted
            capacity = (partition["_end_lba"] - partition["_start_lba"] + 1) * sector_size
            if source.stat().st_size > capacity:
                raise ValueError(f"partition image {filename} does not fit in {partition['name']}")
            offset = partition["_start_lba"] * sector_size
            print(f"  {filename} -> {partition['name']} at LBA {partition['_start_lba']}")
            dd(source, image, offset)
        finally:
            if converted is not None:
                converted.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle_dir", type=pathlib.Path)
    parser.add_argument("output_img", type=pathlib.Path)
    parser.add_argument("--layout", default="external-flash.xml.in")
    parser.add_argument("--device-type", default="external")
    args = parser.parse_args()
    try:
        num_sectors, partitions = parse_layout(args.bundle_dir, args.layout,
                                               args.device_type)
        total_bytes = num_sectors * SECTOR_SIZE
        print(f"Creating {total_bytes / 2**30:.1f} GiB sparse image: {args.output_img}")
        subprocess.run(["truncate", "-s", str(total_bytes), str(args.output_img)], check=True)
        create_gpt(args.output_img, partitions)
        write_partitions(args.output_img, partitions, args.bundle_dir)
    except (OSError, ValueError, ET.ParseError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}")
        return 1
    print(f"Done: {args.output_img}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
