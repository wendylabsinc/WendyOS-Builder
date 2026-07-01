#!/usr/bin/env python3
"""
Create an offline raw NVMe disk image for Jetson AGX Thor from a tegraflash bundle.

Thor (L4T 38.4.x / JetPack 7.1 / T264) ships a 'tegraflash-tar' bundle that
does not include doexternal.sh.  This script reimplements the same offline GPT
image creation that doexternal.sh provides for Orin/Nano:

  1. Parse external-flash.xml.in for the partition layout.
  2. Create a sparse disk image with the correct total size.
  3. Write a GPT partition table using sgdisk.
  4. Copy each partition's binary content at the right sector offset.
     .simg files (Android sparse ext4) are converted with simg2img first.

Requires: sgdisk (gdisk package), simg2img (android-sdk-libsparse-utils package)

Usage:
    python3 make-thor-nvme-img.py <bundle_dir> <output_img>
"""

import argparse
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

LAYOUT_XML = "external-flash.xml.in"


def _parse_xml_safe(xml_path):
    """Parse XML with external entity processing disabled.

    stdlib xml.etree.ElementTree is vulnerable to XXE and billion-laughs
    attacks by default.  Disabling UseForeignDTD and setting
    XML_PARAM_ENTITY_PARSING_NEVER (=2) on the underlying expat parser
    prevents both without requiring a third-party dependency.
    """
    parser = ET.XMLParser()
    if hasattr(parser, "parser"):
        parser.parser.UseForeignDTD(False)
        parser.parser.SetParamEntityParsing(2)  # XML_PARAM_ENTITY_PARSING_NEVER
    return ET.parse(xml_path, parser=parser)


def parse_layout(bundle_dir):
    xml_path = os.path.join(bundle_dir, LAYOUT_XML)
    tree = _parse_xml_safe(xml_path)
    root = tree.getroot()

    device = root.find('.//device[@type="external"]')
    if device is None:
        sys.exit(f"ERROR: no <device type='external'> found in {xml_path}")

    sector_size = int(device.get("sector_size", "512"))
    num_sectors = int(device.get("num_sectors"))

    partitions = []
    for p in device.findall("partition"):
        ptype = p.get("type", "data")
        if ptype in ("protective_master_boot_record", "primary_gpt", "secondary_gpt"):
            continue
        name = p.get("name")
        part_id_str = p.get("id")
        size_text = p.find("size").text.strip()
        size_bytes = int(size_text, 0)  # handles 0x-prefixed hex
        fn_el = p.find("filename")
        filename = fn_el.text.strip() if fn_el is not None and fn_el.text else None
        guid_el = p.find("partition_type_guid")
        type_guid = guid_el.text.strip() if guid_el is not None and guid_el.text else None
        partitions.append({
            "name": name,
            "id": int(part_id_str) if part_id_str else None,
            "size_bytes": size_bytes,
            "filename": filename,
            "type_guid": type_guid,
        })

    return sector_size, num_sectors, partitions


def assign_gpt_numbers(partitions):
    """Assign GPT partition numbers to entries whose XML lacks an explicit id."""
    used = {p["id"] for p in partitions if p["id"] is not None}
    next_num = 1
    for p in partitions:
        if p["id"] is None:
            while next_num in used:
                next_num += 1
            p["id"] = next_num
            used.add(next_num)
            next_num += 1


def create_gpt(img_path, sector_size, partitions):
    """Write a GPT partition table onto img_path using sgdisk.

    Uses -a 1 (1-sector alignment) to place partitions at the exact sector
    offsets computed from the XML, matching the NVIDIA tegraflash layout.
    """
    # GPT primary header occupies LBAs 0-33 (sector 0 = MBR, 1-33 = GPT header
    # + partition entries).  First usable LBA is 34.
    current_lba = 34

    # --clear resets alignment to the default (2048 sectors); -a 1 must come
    # after --clear so the 1-sector alignment takes effect for --new entries.
    cmd = ["sgdisk", "--clear", "-a", "1"]

    for p in partitions:
        size_sectors = (p["size_bytes"] + sector_size - 1) // sector_size
        start_lba = current_lba
        end_lba = start_lba + size_sectors - 1
        pnum = p["id"]

        cmd += [f"--new={pnum}:{start_lba}:{end_lba}"]
        cmd += [f"--change-name={pnum}:{p['name']}"]
        if p["type_guid"]:
            cmd += [f"--typecode={pnum}:{p['type_guid']}"]

        # Stash for use in write_partitions
        p["_start_lba"] = start_lba
        current_lba += size_sectors

    cmd.append(img_path)
    subprocess.run(cmd, check=True)


def write_partitions(img_path, partitions, bundle_dir, sector_size):
    """Copy each partition's source file into the disk image at the right offset."""
    for p in partitions:
        if not p.get("filename"):
            continue
        src = os.path.join(bundle_dir, p["filename"])
        if not os.path.exists(src):
            print(f"  WARNING: {p['filename']} not found — leaving partition '{p['name']}' empty")
            continue

        offset = p["_start_lba"] * sector_size
        print(f"  {p['filename']} -> '{p['name']}' at byte offset {offset:#x} (LBA {p['_start_lba']})")

        if p["filename"].endswith(".simg"):
            raw_path = src + ".raw"
            print(f"    Converting Android sparse image...")
            subprocess.run(["simg2img", src, raw_path], check=True)
            _dd(raw_path, img_path, offset)
            os.remove(raw_path)
        else:
            _dd(src, img_path, offset)


def _dd(src, dst, byte_offset):
    subprocess.run(
        [
            "dd",
            f"if={src}",
            f"of={dst}",
            "bs=4M",
            "conv=notrunc,sparse",
            f"seek={byte_offset}",
            "oflag=seek_bytes",
        ],
        check=True,
    )


def main():
    parser = argparse.ArgumentParser(
        description="Build an offline NVMe GPT disk image for Jetson AGX Thor."
    )
    parser.add_argument("bundle_dir", help="Extracted tegraflash bundle directory")
    parser.add_argument("output_img", help="Output raw NVMe disk image path")
    args = parser.parse_args()

    print(f"Parsing partition layout from {LAYOUT_XML}...")
    sector_size, num_sectors, partitions = parse_layout(args.bundle_dir)
    assign_gpt_numbers(partitions)

    total_bytes = num_sectors * sector_size
    print(f"Disk geometry: {num_sectors} × {sector_size} B = {total_bytes / 2**30:.1f} GiB")

    print(f"Creating sparse disk image: {args.output_img}")
    subprocess.run(["truncate", "-s", str(total_bytes), args.output_img], check=True)

    print("Writing GPT partition table...")
    create_gpt(args.output_img, sector_size, partitions)

    print("Writing partition content:")
    write_partitions(args.output_img, partitions, args.bundle_dir, sector_size)

    du = subprocess.run(["du", "-sh", args.output_img], capture_output=True, text=True)
    print(f"\nDone: {args.output_img}")
    print(f"  Nominal size : {total_bytes / 2**30:.1f} GiB")
    print(f"  Actual usage : {du.stdout.strip()}")


if __name__ == "__main__":
    main()
