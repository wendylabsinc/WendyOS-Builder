#!/usr/bin/env bash
# First-boot reclaim of the consumed WendyOS /config partition into /data.
#
# `wendy os install` seeds the FAT32 /config partition (label "config") with
# first-boot provisioning; wendy-agent consumes and ERASES it on first boot
# (configpartition.Apply), persisting anything durable to /etc/wendyos (/data).
# Mender lays this extra partition AFTER /data, so /data cannot grow to fill the
# card. Once /config is drained we delete it and grow /data over the freed +
# trailing space — the grow-to-any-card behaviour mender-growfs-data gives on
# stock (data-last) layouts.
#
# Resumable: an .inprogress marker is written before the irreversible `parted
# rm`, so a power loss / failure between the delete and the resize is recovered
# on the next boot instead of stranding /data at its image size. The done-stamp
# is written ONLY after the kernel confirms /data fills the disk.
set -uo pipefail

STAMP="/data/.wendyos-reclaim-config.done"
INPROGRESS="/data/.wendyos-reclaim-config.inprogress"
LOG="/var/log/reclaim-config-part.log"
CONFIG_MNT="/config"
CONFIG_LABEL="config"
SEED_FILES=("wendy-agent" "wendy.conf" "provisioning.json")
DRAIN_TIMEOUT=120   # seconds to wait for wendy-agent to drain /config
END_SLACK=8192      # sectors (4 MiB) of trailing slack tolerated as "fills disk"

touch "$LOG" 2>/dev/null && exec > >(tee -a "$LOG") 2>&1 || true
log() { echo "[reclaim-config] $*"; }
defer() { log "$* -- deferring to next boot."; exit 0; }   # expected; quiet retry
fail()  { log "ERROR: $*"; exit 1; }                        # surfaced via systemd

log "Start $(date -Is 2>/dev/null || true)"
[ -f "$STAMP" ] && { log "Stamp present; nothing to do."; exit 0; }

# --- Resolve /data, its disk, and partition number FIRST. Everything is scoped
# to the disk /data lives on, so external media labelled "config" is never
# touched. ----------------------------------------------------------------
DATA_DEV="$(findmnt -n -o SOURCE /data 2>/dev/null || true)"
case "$DATA_DEV" in /dev/*) ;; *) defer "cannot resolve /data to a block device ('$DATA_DEV')";; esac
data_base="$(basename "$DATA_DEV")"
DATA_NUM="$(cat "/sys/class/block/$data_base/partition" 2>/dev/null)" || defer "cannot read /data partition number"
DISK="/dev/$(basename "$(readlink -f "/sys/class/block/$data_base/.." 2>/dev/null)")"
disk_base="$(basename "$DISK")"
[ -b "$DISK" ] || defer "could not resolve parent disk of /data ('$DISK')"

# Grow the (possibly logical, inside an MBR extended) /data partition to the end
# of the disk and grow ext4 onto it. Idempotent: every step is a no-op if /data
# already fills the disk, so this is safe to re-run on resume.
grow_data_to_fill() {
    local ext_dev ext_num disk_sz data_start data_sz end
    # MBR: grow the extended container first so the logical /data can expand.
    ext_dev="$(sfdisk -d "$DISK" 2>/dev/null | awk 'tolower($0) ~ /type=[ ]*0?[5f]([^0-9a-f]|$)/ {print $1; exit}')"
    if [ -n "$ext_dev" ]; then
        ext_num="$(cat "/sys/class/block/$(basename "$ext_dev")/partition" 2>/dev/null || true)"
        [ -n "$ext_num" ] && { log "Growing extended partition #$ext_num"; parted -s "$DISK" resizepart "$ext_num" 100% || true; }
    fi
    log "Growing data partition #$DATA_NUM"
    parted -s "$DISK" resizepart "$DATA_NUM" 100% || { log "parted resizepart /data failed"; return 1; }
    partprobe "$DISK" 2>/dev/null || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

    # Verify the KERNEL now sees /data reaching the disk end before touching the
    # filesystem. Catches the case where the in-kernel table was not refreshed
    # for a mounted disk (which would otherwise make resize2fs a silent no-op).
    disk_sz="$(cat "/sys/class/block/$disk_base/size" 2>/dev/null || echo 0)"
    data_start="$(cat "/sys/class/block/$data_base/start" 2>/dev/null || echo 0)"
    data_sz="$(cat "/sys/class/block/$data_base/size" 2>/dev/null || echo 0)"
    end=$((data_start + data_sz))
    if [ "$disk_sz" -le 0 ] || [ "$end" -lt $((disk_sz - END_SLACK)) ]; then
        log "kernel /data partition does not fill disk yet (end=$end of $disk_sz sectors)"
        return 1
    fi
    log "Growing ext4 on $DATA_DEV (online)"
    resize2fs "$DATA_DEV" || { log "resize2fs failed"; return 1; }
    return 0
}

# Grow succeeded: clear the in-progress marker, stamp done, and (re)trigger swap
# setup, which swapfile-setup.service skipped earlier when /data was still small.
finish() {
    rm -f "$INPROGRESS"
    mkdir -p "$(dirname "$STAMP")" && touch "$STAMP"
    command -v systemctl >/dev/null 2>&1 && systemctl restart --no-block swapfile-setup.service 2>/dev/null || true
    log "Reclaim complete; /data fills the device. $(date -Is 2>/dev/null || true)"
    exit 0
}

# Find the config partition by filesystem label, restricted to this disk.
find_config() {
    local name label
    while read -r name label; do
        [ "$label" = "$CONFIG_LABEL" ] && { echo "/dev/$name"; return 0; }
    done < <(lsblk -rno NAME,LABEL "$DISK" 2>/dev/null)
    return 1
}
# Ensure udev has populated filesystem labels before deciding whether a "config"
# partition exists: lsblk reads LABEL from the udev db, which can lag the kernel
# partition table on a cold boot (NAME is from sysfs and is always present).
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true
CONFIG_DEV="$(find_config || true)"

# --- No config partition on this disk. Either an interrupted earlier run
# (resume), a transient lsblk miss (retry), or genuinely nothing to do. -----
if [ -z "$CONFIG_DEV" ]; then
    if [ -f "$INPROGRESS" ]; then
        log "config already deleted by an earlier run; resuming /data grow."
        grow_data_to_fill && finish
        fail "could not finish /data grow on resume"   # marker persists -> retry next boot
    fi
    # Only trust "no config" if lsblk actually enumerated this disk's partitions.
    # Capture first: `lsblk | grep -q` would SIGPIPE lsblk and, under pipefail,
    # report failure even on a match.
    disk_names="$(lsblk -rno NAME "$DISK" 2>/dev/null)"
    grep -qx "$data_base" <<<"$disk_names" \
        || defer "lsblk did not enumerate $DISK; not trusting 'no config'"
    log "No '$CONFIG_LABEL' partition on $DISK; nothing to reclaim."
    mkdir -p "$(dirname "$STAMP")" && touch "$STAMP"
    exit 0
fi
log "config partition: $CONFIG_DEV"

cfg_base="$(basename "$CONFIG_DEV")"
CONFIG_NUM="$(cat "/sys/class/block/$cfg_base/partition" 2>/dev/null)" || defer "cannot read config partition number"

# Ensure /config is mounted so we can confirm the agent has drained it.
if ! findmnt -n "$CONFIG_MNT" >/dev/null 2>&1; then
    mkdir -p "$CONFIG_MNT"; mount "$CONFIG_DEV" "$CONFIG_MNT" 2>/dev/null || true
fi
findmnt -n "$CONFIG_MNT" >/dev/null 2>&1 || defer "$CONFIG_MNT is not mounted"

# Wait (bounded) for wendy-agent to consume + erase the seed files.
config_drained() { local f; for f in "${SEED_FILES[@]}"; do [ -e "$CONFIG_MNT/$f" ] && return 1; done; return 0; }
waited=0
until config_drained; do
    [ "$waited" -ge "$DRAIN_TIMEOUT" ] && defer "agent has not drained /config after ${DRAIN_TIMEOUT}s"
    sleep 5; waited=$((waited + 5))
done
log "/config drained by agent."

# Safety: config must be the physically last partition (highest start) and after
# /data, so we only ever grow /data forward into reclaimed/trailing space. Read
# failures are fatal-to-defer, never silently treated as "ok".
cfg_start="$(cat "/sys/class/block/$cfg_base/start" 2>/dev/null)" || defer "cannot read config start sector"
data_start="$(cat "/sys/class/block/$data_base/start" 2>/dev/null)" || defer "cannot read /data start sector"
max_start=0
for p in /sys/class/block/"$disk_base"*/start; do
    [ -r "$p" ] || continue
    s="$(cat "$p" 2>/dev/null)" || defer "cannot read a partition start sector"
    [ "$s" -gt "$max_start" ] && max_start="$s"
done
[ "$cfg_start" -eq "$max_start" ] || defer "config (start=$cfg_start) is not the last partition (max=$max_start)"
[ "$cfg_start" -gt "$data_start" ] || defer "config is not after /data (cfg=$cfg_start data=$data_start)"

# --- Surgery. The .inprogress marker (written before the irreversible rm) makes
# any failure after this point resumable on the next boot. ------------------
log "Unmounting $CONFIG_MNT"
umount "$CONFIG_MNT" 2>/dev/null || umount "$CONFIG_DEV" 2>/dev/null || true
findmnt -n "$CONFIG_MNT" >/dev/null 2>&1 && defer "could not unmount $CONFIG_MNT"

mkdir -p "$(dirname "$INPROGRESS")" && touch "$INPROGRESS"
log "Deleting config partition #$CONFIG_NUM"
parted -s "$DISK" rm "$CONFIG_NUM" || fail "parted rm failed"

grow_data_to_fill && finish
fail "/data grow failed after deleting config"   # marker persists -> resumed next boot
