#!/usr/bin/env bash
#
# First-boot initialisation of the persistent /data partition for the
# wendy-update OTA stack (replaces Mender's mender-grow-data).
#
# The partition is carved into the flash layout allocated-empty (no
# <filename> — see tegra_partition_config.bbclass), so on first boot it
# has no filesystem. This script, run once before data.mount:
#   1. resolves the partition by GPT label "data",
#   2. if it already holds an ext4 filesystem -> nothing to do,
#   3. otherwise: fix the GPT backup header (the image is flashed to a
#      disk far larger than the layout), grow the partition to fill the
#      disk, and mkfs.ext4 it.
#
# Idempotency keys on the FILESYSTEM, not a stamp file: the rootfs is A/B
# and swapped by OTA, so a per-rootfs stamp would be absent on the other
# slot and could trigger a re-format that wipes /data. Checking for an
# existing ext4 is slot-independent and safe.
set -euo pipefail

log() { printf '[wendyos-data-init] %s\n' "$*"; }

BYLABEL="/dev/disk/by-partlabel/data"

# Wait briefly for udev to create the by-partlabel link.
for _ in $(seq 1 10); do
    [ -e "${BYLABEL}" ] && break
    udevadm settle 2>/dev/null || true
    sleep 1
done
if [ ! -e "${BYLABEL}" ]; then
    log "no partition labelled 'data' found; nothing to do"
    exit 0
fi

DEV="$(readlink -f "${BYLABEL}")"
log "data partition: ${DEV}"

# Already initialised? (slot-safe idempotency)
if [ "$(blkid -o value -s TYPE "${DEV}" 2>/dev/null || true)" = "ext4" ]; then
    log "already ext4; nothing to do"
    exit 0
fi

# Resolve parent disk + partition number via sysfs (portable across
# nvme0n1pN / mmcblk0pN).
PART_BASENAME="$(basename "${DEV}")"
PARTNUM="$(cat "/sys/class/block/${PART_BASENAME}/partition")"
PARENT_SYS="$(readlink -f "/sys/class/block/${PART_BASENAME}/..")"
DISK="/dev/$(basename "${PARENT_SYS}")"
log "disk=${DISK} partnum=${PARTNUM}"

# The image is flashed onto a disk much larger than the flash layout, so
# the GPT backup header sits mid-disk. Move it to the real end so the
# free space becomes usable, then grow the (last) data partition into it.
if command -v sgdisk >/dev/null 2>&1; then
    log "sgdisk -e ${DISK} (relocate GPT backup header)"
    sgdisk -e "${DISK}" || true
    partprobe "${DISK}" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
fi

log "parted resizepart ${PARTNUM} 100%"
parted -s "${DISK}" unit % resizepart "${PARTNUM}" 100% || true
partprobe "${DISK}" 2>/dev/null || true
udevadm settle 2>/dev/null || true

log "mkfs.ext4 -L data ${DEV}"
mkfs.ext4 -F -L data "${DEV}"

log "done"
