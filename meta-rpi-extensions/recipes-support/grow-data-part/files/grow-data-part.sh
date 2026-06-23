#!/usr/bin/env bash
# Grow /data to fill the storage device on first boot, no reboot.
#
# config (FAT) sits BEFORE /data (mender-config-before-data.bbclass), so /data is
# the LAST partition and grows into the trailing free space. Stock mender-growfs-data
# is disabled: it can't resize the MBR *extended* container holding the logical /data.
#
# Split in two (mirrors Tegra's mender-grow-data + mender-systemd-growfs-data) so the
# slow ext4 grow stays off the boot path -- see the partition/resize/all case below.
# Idempotent throughout: safe to run on every boot.
set -uo pipefail

MODE="${1:-all}"

END_SLACK=8192   # sectors (4 MiB) of trailing slack tolerated as "fills the disk"
LOG="/run/grow-data-part.log"   # /data and /var/log may not be mounted yet

touch "$LOG" 2>/dev/null && exec > >(tee -a "$LOG") 2>&1 || true   # journal is the fallback sink
log()   { echo "[grow-data:${MODE}] $*"; }
defer() { log "$* -- deferring to a later boot."; exit 0; }   # expected, transient
fail()  { log "ERROR: $*"; exit 1; }                          # surfaced via systemctl --failed

# Read a sysfs block attribute (start, size, partition) for a kernel block name.
sysblk() { cat "/sys/class/block/$1/$2" 2>/dev/null; }

log "Start $(date -Is 2>/dev/null || true)"

# Mender's fstab references /data by raw device path; read it so we don't hardcode
# the partition number (both phases need the device).
DATA_DEV="$(awk '$1 !~ /^#/ && $2 == "/data" { print $1; exit }' /etc/fstab 2>/dev/null || true)"
case "$DATA_DEV" in
    /dev/*) ;;
    *) fail "no usable /data device in /etc/fstab ('$DATA_DEV')" ;;
esac
[ -b "$DATA_DEV" ] || defer "$DATA_DEV not present yet"
data_base="$(basename "$DATA_DEV")"

resolve_disk() {
    DATA_NUM="$(sysblk "$data_base" partition)" || defer "cannot read /data partition number"
    DISK="/dev/$(basename "$(readlink -f "/sys/class/block/$data_base/.." 2>/dev/null)")"
    disk_base="$(basename "$DISK")"
    [ -b "$DISK" ] || defer "cannot resolve parent disk of /data"
}

# True when the kernel sees the /data PARTITION (not its fs) reaching the disk end
# within slack. Gates the partition grow only; never treated as "fully grown".
data_fills_disk() {
    local disk_sz d_start d_sz
    disk_sz="$(sysblk "$disk_base" size  || echo 0)"
    d_start="$(sysblk "$data_base" start || echo 0)"
    d_sz="$(sysblk "$data_base"  size   || echo 0)"
    [ "$disk_sz" -gt 0 ] && [ $((d_start + d_sz)) -ge $((disk_sz - END_SLACK)) ]
}

# Extend /data to the disk end. It's a logical partition inside an MBR extended
# container, so the container must be grown first (below).
grow_data_partition() {
    local ext_dev ext_num
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

# Repair here while /data is unmounted -- the online resize can't fsck a mounted fs.
# `e2fsck -p` without -f honours the clean flag, so it's near-instant unless dirty.
ensure_fs_clean() {
    e2fsck -p "$DATA_DEV"; local ec=$?
    [ "$ec" -ge 4 ] && { log "e2fsck could not repair $DATA_DEV (rc=$ec)"; return 1; }
    return 0
}

# Offline phase: grow the partition and leave the fs clean for the online resize.
# Deliberately no resize2fs here -- that's the slow step, deferred to do_resize.
do_partition() {
    resolve_disk
    data_fills_disk || grow_data_partition || fail "could not grow /data partition"
    ensure_fs_clean || fail "/data filesystem is unclean and could not be repaired"
    log "Partition fills the device; /data ready to mount."
}

# Online phase: resize2fs grows the MOUNTED /data in place. On failure, stay failed
# so the unit retries next boot.
do_resize() {
    resize2fs "$DATA_DEV" && { log "/data filesystem fills the partition."; exit 0; }
    fail "online resize2fs of $DATA_DEV failed (will retry next boot)"
}

case "$MODE" in
    partition) do_partition ;;
    resize)    do_resize ;;
    all)       # Manual/recovery: partition grow + e2fsck are valid only while /data
               # is unmounted; once mounted, only the online resize is safe.
               if grep -qs ' /data ' /proc/mounts; then
                   log "/data is mounted; online resize only"
                   do_resize
               else
                   do_partition
                   resize2fs "$DATA_DEV" && { log "/data fills the device."; exit 0; }
                   fail "could not grow /data filesystem"
               fi ;;
    *) fail "unknown mode '$MODE' (expected: partition | resize | all)" ;;
esac
