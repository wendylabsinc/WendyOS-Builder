#!/usr/bin/env bash
#
# First-boot initialisation of the persistent /data partition for the
# wendyos-update OTA stack.
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

# Trailing slack (~4 MiB) tolerated as "fills the disk", mirroring data-enroll.sh.
END_SLACK=8192

# Never fails: a missing attribute yields the empty string, so the callers'
# assignments cannot trip set -e.
sysblk() {
    cat "/sys/class/block/$1/$2" 2>/dev/null || true
}

# True when the kernel sees the /data PARTITION reaching the disk end within
# slack. Same predicate as data_fills_disk() in data-enroll.sh and
# grow-data-part.sh; reads the globals resolved below.
data_fills_disk() {
    local disk_base
    local disk_sz
    local part_start
    local part_sz
    disk_base="$(basename "${PARENT_SYS}")"
    disk_sz="$(sysblk "${disk_base}" size)"
    part_start="$(sysblk "${PART_BASENAME}" start)"
    part_sz="$(sysblk "${PART_BASENAME}" size)"
    disk_sz="${disk_sz:-0}"
    part_start="${part_start:-0}"
    part_sz="${part_sz:-0}"
    [ "${disk_sz}" -gt 0 ] && [ "$(( part_start + part_sz ))" -ge "$(( disk_sz - END_SLACK ))" ]
}

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

# Resolve parent disk + partition number via sysfs (portable across
# nvme0n1pN / mmcblk0pN). Resolved here, before the guards below, because
# the LUKS guard needs data_fills_disk.
PART_BASENAME="$(basename "${DEV}")"
PARTNUM="$(cat "/sys/class/block/${PART_BASENAME}/partition")"
PARENT_SYS="$(readlink -f "/sys/class/block/${PART_BASENAME}/..")"
DISK="/dev/$(basename "${PARENT_SYS}")"
log "disk=${DISK} partnum=${PARTNUM}"

# Never touch an encrypted /data. blkid reports "crypto_LUKS" (not "ext4")
# for a volume created by a TPM-enabled build, so without this guard we fall
# through and mkfs.ext4 -F over the LUKS container. The dangerous case is
# automatic: an A/B rollback from a TPM-on slot to an older TPM-off slot,
# where nobody chooses the wipe. Mirror of the migration guard in
# data-enroll.sh -- refuse, exit 0, leave the partition untouched.
#
# But "is LUKS" alone is not enough. A reflash recreates this partition at its
# small stock size WITHOUT zeroing the disk, and its start offset is unchanged,
# so the previous installation's LUKS header is still physically there. An
# enrolled /data always fills the disk (data-enroll.sh grows before formatting
# and fails hard otherwise), so: LUKS + fills-disk = live data, refuse;
# LUKS + small partition = stale header, reinitialise.
if [ "$(blkid -o value -s TYPE "${DEV}" 2>/dev/null || true)" = "crypto_LUKS" ]; then
    if data_fills_disk; then
        log "REFUSING to initialise ${DEV}: it is an ENCRYPTED (LUKS) /data from a TPM-enabled installation -- reformatting it would destroy all user data."
        log "Leaving the partition untouched; /data will NOT be mounted on this boot. Boot a TPM-enabled image (or re-flash) to use this device."
        exit 0
    fi
    log "LUKS header present but the partition does not fill the disk: stale header from a previous install (a reflash recreated the partition without zeroing it); reinitialising"
    # fall through to grow + mkfs
fi

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
