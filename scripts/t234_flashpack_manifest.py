#!/usr/bin/env python3
"""Generate and validate the consumed T234 recovery flashpack schema v2."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

SCHEMA = 2
PROTOCOL = "usb-mass-storage-v1"
USB_PRODUCT_ID = "0x7023"

# Partition types the host CLI generates natively (protective MBR + both GPT
# copies) instead of reading from the flashpack — see tegraflash/t234/plan.go,
# which skips exactly these. They carry a <filename> in the layout but are never
# staged into stage2/flash, so validation must skip them too.
HOST_GENERATED_PARTITION_TYPES = frozenset({
    "protective_master_boot_record",
    "primary_gpt",
    "secondary_gpt",
})

TARGETS = {
    ("jetson-orin-nano", "nvme"): {
        "module_id": "3767", "module_sku": "0005",
        "carrier_id": "3768", "carrier_sku": "0000",
        "rootfs_device": "nvme0n1",
        "machine": "jetson-orin-nano-devkit-nvme-wendyos",
    },
    ("jetson-agx-orin", "nvme"): {
        "module_id": "3701", "module_sku": "0005",
        "carrier_id": "3737", "carrier_sku": "0000",
        "rootfs_device": "nvme0n1",
        "machine": "jetson-agx-orin-devkit-nvme-wendyos",
    },
    ("jetson-agx-orin", "emmc"): {
        "module_id": "3701", "module_sku": "0005",
        "carrier_id": "3737", "carrier_sku": "0000",
        "rootfs_device": "mmcblk0",
        "machine": "jetson-agx-orin-devkit-emmc-wendyos",
    },
}


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_file(root: pathlib.Path, relative: str) -> pathlib.Path:
    path = root / relative
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"required regular file is missing: {relative}")
    return path


def parse_rcm_phases(root: pathlib.Path) -> list[list[dict[str, str]]]:
    command = require_file(root, "stage1/rcmbootcmd.txt").read_text()
    phases: list[list[dict[str, str]]] = []
    for line in command.splitlines():
        downloads = re.findall(r"--download\s+(\S+)\s+(\S+)", line)
        if downloads:
            phase = [{"type": kind, "file": f"stage1/{pathlib.Path(name).name}"}
                     for kind, name in downloads]
            for item in phase:
                require_file(root, item["file"])
            phases.append(phase)
    if len(phases) != 2:
        raise ValueError(f"expected exactly two RCM phases, got {len(phases)}")
    if not any(item["type"] == "bct_mem" for item in phases[1]):
        raise ValueError("second RCM phase omits bct_mem")
    if not any(item["type"] == "blob" for item in phases[1]):
        raise ValueError("second RCM phase omits blob")
    return phases


def validate_partition_images(root: pathlib.Path, layout: str,
                              rootfs_device: str) -> str:
    tree = ET.parse(require_file(root, layout))
    device_type = "sdmmc_user" if rootfs_device == "mmcblk0" else "external"
    devices = [device for device in tree.findall(".//device")
               if device.get("type") == device_type]
    if len(devices) != 1:
        raise ValueError(
            f"partition layout must contain exactly one {device_type} rootfs device, "
            f"got {len(devices)}"
        )
    filenames: list[str] = []
    for partition in devices[0].findall("partition"):
        if (partition.get("type") or "").strip() in HOST_GENERATED_PARTITION_TYPES:
            continue
        name = (partition.findtext("filename") or "").strip()
        if name:
            filenames.append(name)
            require_file(root, f"stage2/flash/{name}")
    configs = sorted({name for name in filenames if pathlib.Path(name).name == "config-partition.fat32.img"})
    if len(configs) != 1:
        raise ValueError(f"partition layout must reference exactly one config image, got {configs}")
    return f"stage2/flash/{configs[0]}"


def generate(root: pathlib.Path, *, version: str, device: str, storage: str,
             machine: str, board_id: str, board_sku: str, board_fab: str,
             board_rev: str, chip_sku: str, rootfs_device: str,
             boot_device_type: str, rootfs_image: str) -> dict:
    target = TARGETS.get((device, storage))
    if target is None:
        raise ValueError(f"unsupported T234 recovery target {device}/{storage}")
    if board_id != target["module_id"] or board_sku.zfill(4) != target["module_sku"]:
        raise ValueError(
            f"bundle module P{board_id}-{board_sku} does not match target "
            f"P{target['module_id']}-{target['module_sku']}"
        )
    if machine != target["machine"]:
        raise ValueError(
            f"bundle machine {machine} does not match supported {device}/{storage} "
            f"machine {target['machine']}"
        )
    if rootfs_device != target["rootfs_device"]:
        raise ValueError(f"rootfs device {rootfs_device} does not match {device}/{storage}")

    flash_package = "stage2/flashpkg.ext4"
    partition_layout = "stage2/flash/initrd-flash.xml"
    status_path = "flashpkg/status"
    logs_path = "flashpkg/logs"
    flash_package_path = require_file(root, flash_package)
    if flash_package_path.stat().st_size != 128 << 20:
        raise ValueError("flash package must be exactly 128 MiB")
    config_image = validate_partition_images(root, partition_layout, rootfs_device)
    phases = parse_rcm_phases(root)
    if not (root / "stage2/flashpkg/status").is_file():
        raise ValueError("flash package status template is missing")
    if not (root / "stage2/flashpkg/logs").is_dir():
        raise ValueError("flash package log directory is missing")

    files: dict[str, dict[str, int | str]] = {}
    for path in sorted(root.rglob("*")):
        if path.name == "manifest.json":
            continue
        if path.is_symlink():
            raise ValueError(f"flashpack contains a symlink: {path.relative_to(root)}")
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            files[relative] = {"sha256": sha256(path), "size": path.stat().st_size}

    consumed = [flash_package, partition_layout, config_image]
    consumed.extend(item["file"] for phase in phases for item in phase)
    missing = [path for path in consumed if path not in files]
    if missing:
        raise ValueError(f"integrity map omits consumed files: {missing}")

    return {
        "schema": SCHEMA,
        "family": "t234",
        "protocol": PROTOCOL,
        "usb_product_id": USB_PRODUCT_ID,
        "wendyos_version": version,
        "target": {
            "device": device,
            "storage": storage,
            "module_id": target["module_id"],
            "module_sku": target["module_sku"],
            "carrier_id": target["carrier_id"],
            "carrier_sku": target["carrier_sku"],
        },
        "rcm_phases": phases,
        "layout": {
            "stage1": "stage1",
            "flash_package_image": flash_package,
            "flash_package_status": status_path,
            "flash_package_logs": logs_path,
            "flash_images": "stage2/flash",
            "partition_layout": partition_layout,
            "config_image": config_image,
        },
        "rootfs_device": rootfs_device,
        "files": files,
        "machine": machine,
        "chip": "0x23",
        "board_id": board_id,
        "board_fab": board_fab,
        "board_sku": board_sku,
        "board_rev": board_rev,
        "chip_sku": chip_sku or None,
        "boot_device_type": boot_device_type,
        "rootfs_image": rootfs_image,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=pathlib.Path)
    for name in ("version", "device", "storage", "machine", "board-id", "board-sku",
                 "board-fab", "board-rev", "chip-sku", "rootfs-device",
                 "boot-device-type", "rootfs-image"):
        parser.add_argument(f"--{name}", required=name not in {"board-rev", "chip-sku"}, default="")
    args = parser.parse_args()
    try:
        manifest = generate(
            args.root, version=args.version, device=args.device, storage=args.storage,
            machine=args.machine, board_id=args.board_id, board_sku=args.board_sku,
            board_fab=args.board_fab, board_rev=args.board_rev, chip_sku=args.chip_sku,
            rootfs_device=args.rootfs_device, boot_device_type=args.boot_device_type,
            rootfs_image=args.rootfs_image,
        )
        (args.root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    except (OSError, ValueError, ET.ParseError) as exc:
        print(f"ERR: {exc}", file=sys.stderr)
        return 1
    print(f"manifest v{SCHEMA}: {len(manifest['files'])} files hashed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
