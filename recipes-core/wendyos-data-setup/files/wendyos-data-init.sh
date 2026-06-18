#!/usr/bin/env bash
#
# First-boot initialisation of the persistent /data partition for the
# wendyos-update OTA stack (replaces Mender's mender-grow-data).
#
# The partition is carved into the flash layout allocated-empty (no
# <filename> — see tegra_partition_config.bbclass), so on first boot it
# has no filesystem. This script, run once before data.mount:
#   1. resolves the partition by GPT label "data",
#   2. if it already holds an ext4 filesystem that fits the partition ->
#      nothing to do (a stale superblock from a prior larger layout does
#      not count — see the guard below),
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

# Already initialised? (slot-safe idempotency — key on the filesystem,
# not a per-rootfs stamp). But "blkid reports ext4" is not sufficient: a
# reflash recreates this partition at its small initial size while leaving
# behind the superblock of a previously-grown filesystem. blkid still sees
# ext4, yet the kernel refuses the mount with "bad geometry: block count N
# exceeds size of device". Treat the fs as initialised only if it also
# physically fits the partition; otherwise it is a stale superblock and we
# must grow + reformat (the mkfs.ext4 -F below overwrites it).
if [ "$(blkid -o value -s TYPE "${DEV}" 2>/dev/null || true)" = "ext4" ]; then
    # Treat the fs as initialised only if dumpe2fs can read it AND it
    # physically fits the device. A stale superblock that overshoots the
    # device (the case this guard repairs) makes dumpe2fs exit non-zero, so
    # a dumpe2fs failure -> reinitialise. The assignment sits in the `if`
    # test, which set -e exempts, so a non-zero dumpe2fs cannot abort the
    # script — and we never rely on parsing partial output. dumpe2fs's
    # stderr is captured and logged on failure so the reason (e.g. "fs size
    # larger than physical size") is visible in the journal.
    de2fs_err="$(mktemp 2>/dev/null || printf '%s' /tmp/wendyos-data-init.de2fs)"
    if sb="$(dumpe2fs -h "${DEV}" 2>"${de2fs_err}")"; then
        fs_blocks="$(printf '%s\n' "${sb}" | awk -F: '/^Block count:/{gsub(/ /,"",$2); print $2}')"
        fs_bsize="$(printf '%s\n' "${sb}" | awk -F: '/^Block size:/{gsub(/ /,"",$2); print $2}')"
        dev_bytes="$(blockdev --getsize64 "${DEV}" 2>/dev/null || echo 0)"
        if [ -n "${fs_blocks}" ] && [ -n "${fs_bsize}" ] && [ "${dev_bytes}" -gt 0 ] \
           && [ "$(( fs_blocks * fs_bsize ))" -le "${dev_bytes}" ]; then
            log "already ext4 and fits device; nothing to do"
            rm -f "${de2fs_err}"
            exit 0
        fi
        log "ext4 present but does not fit the device (stale from a prior, larger layout); reinitialising"
    else
        rc=$?
        log "dumpe2fs could not validate the existing fs (exit ${rc}); reinitialising:"
        while IFS= read -r de2fs_line; do
            [ -n "${de2fs_line}" ] && log "  dumpe2fs: ${de2fs_line}"
        done < "${de2fs_err}"
    fi
    rm -f "${de2fs_err}"
    # fall through to grow + mkfs
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
