#!/usr/bin/env bash
# Grow /data to fill the storage device on first boot (offline, no reboot).
#
# On WendyOS RPi the FAT "config" partition sits BEFORE /data (see
# mender-config-before-data.bbclass), so /data is the LAST partition and can grow
# straight into the trailing free space on any card. Mender's stock
# mender-growfs-data is disabled because it cannot resize the MBR *extended*
# container that holds the logical /data; this oneshot does it
# (extended container -> /data -> resize2fs).
#
# The unit orders this before the mount (see grow-data-part.service), so /data is
# UNMOUNTED here and parted/resize2fs can operate. Idempotent: resize2fs no-ops
# once /data already fills its partition, so it's safe to run on every boot.
set -uo pipefail

END_SLACK=8192   # sectors (4 MiB) of trailing slack tolerated as "fills the disk"
LOG="/run/grow-data-part.log"   # /data and /var/log are not mounted yet

touch "$LOG" 2>/dev/null && exec > >(tee -a "$LOG") 2>&1 || true   # journal is the fallback sink
log()   { echo "[grow-data] $*"; }
defer() { log "$* -- deferring to a later boot."; exit 0; }   # expected, transient
fail()  { log "ERROR: $*"; exit 1; }                          # surfaced via systemctl --failed

# Read a sysfs block attribute (start, size, partition) for a kernel block name.
sysblk() { cat "/sys/class/block/$1/$2" 2>/dev/null; }

log "Start $(date -Is 2>/dev/null || true)"

# /data is referenced by raw device path in the Mender-generated fstab and is NOT
# mounted at this stage; resolve it from fstab (works for whatever number it has).
DATA_DEV="$(awk '$1 !~ /^#/ && $2 == "/data" { print $1; exit }' /etc/fstab 2>/dev/null || true)"
case "$DATA_DEV" in
    /dev/*) ;;
    # The wendy (wendyos-update) RPi fstab references /data by label so it can
    # stay machine-agnostic (mmcblk0pN vs nvme0n1pN). Resolve any tag spec to a
    # device node; Mender's generated fstab uses /dev/* and skips this.
    LABEL=*|UUID=*|PARTLABEL=*|PARTUUID=*)
        resolved="$(findfs "$DATA_DEV" 2>/dev/null || true)"
        [ -n "$resolved" ] || defer "cannot resolve /data spec '$DATA_DEV' yet"
        DATA_DEV="$resolved" ;;
    *) fail "no usable /data device in /etc/fstab ('$DATA_DEV')" ;;
esac
[ -b "$DATA_DEV" ] || defer "$DATA_DEV not present yet"
data_base="$(basename "$DATA_DEV")"
DATA_NUM="$(sysblk "$data_base" partition)" || defer "cannot read /data partition number"
DISK="/dev/$(basename "$(readlink -f "/sys/class/block/$data_base/.." 2>/dev/null)")"
disk_base="$(basename "$DISK")"
[ -b "$DISK" ] || defer "cannot resolve parent disk of /data"

# data_fills_disk: does the kernel see the /data PARTITION reaching (within slack
# of) the disk end? Decides whether to (re)grow the partition; the filesystem is
# grown/verified separately, so this is never trusted as "done" on its own.
data_fills_disk() {
    local disk_sz d_start d_sz
    disk_sz="$(sysblk "$disk_base" size  || echo 0)"
    d_start="$(sysblk "$data_base" start || echo 0)"
    d_sz="$(sysblk "$data_base"  size   || echo 0)"
    [ "$disk_sz" -gt 0 ] && [ $((d_start + d_sz)) -ge $((disk_sz - END_SLACK)) ]
}

# grow_data_partition: extend the (logical, inside an MBR extended) /data
# partition to the disk end. /data must be unmounted (we run before its mount).
grow_data_partition() {
    local ext_dev ext_num
    # MBR: grow the extended container first so the logical /data can expand.
    ext_dev="$(sfdisk -d "$DISK" 2>/dev/null | awk 'tolower($0) ~ /type=[ ]*0?[5f]([^0-9a-f]|$)/ { print $1; exit }')"
    if [ -n "$ext_dev" ]; then
        ext_num="$(sysblk "$(basename "$ext_dev")" partition)"
        if [ -n "$ext_num" ]; then
            log "Growing extended partition #$ext_num"
            parted -s "$DISK" resizepart "$ext_num" 100%; rc=$?
            [ "$rc" -ne 0 ] && { log "extended-partition resize failed (rc=$rc)"; return 1; }
        fi
    fi
    log "Growing data partition #$DATA_NUM"
    parted -s "$DISK" resizepart "$DATA_NUM" 100% || { log "parted resizepart /data failed (rc=$?)"; return 1; }
    partprobe "$DISK" 2>/dev/null || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle -t 10 2>/dev/null || true
    data_fills_disk || { log "kernel did not pick up the grown /data partition size"; return 1; }
}

# grow_data_fs: grow ext4 to fill the partition. resize2fs is idempotent -- it
# no-ops (cheap superblock read) when already full. It refuses an unclean fs, so
# on failure run a full offline check (safe: /data is unmounted) and retry once.
grow_data_fs() {
    resize2fs "$DATA_DEV" && return 0
    log "resize2fs refused $DATA_DEV (fs may be unclean); running e2fsck -p -f"
    e2fsck -p -f "$DATA_DEV"; local ec=$?
    [ "$ec" -ge 4 ] && { log "e2fsck could not repair $DATA_DEV (rc=$ec)"; return 1; }
    resize2fs "$DATA_DEV"
}

# Grow the partition (skipped if already at the disk end) then the filesystem.
data_fills_disk || grow_data_partition || fail "could not grow /data partition"
grow_data_fs && { log "/data fills the device."; exit 0; }
fail "could not grow /data filesystem"
