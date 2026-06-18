#!/bin/sh
#
# Mount the WendyOS config partition at /config.
#
# Uses blkid to find the partition by filesystem label directly, without
# relying on the /dev/disk/by-label/config udev symlink (which is absent
# on some platforms such as Jetson Thor / T264).
#

log() { printf '[wendyos-config-mount] %s\n' "$*"; }

# Retry briefly — the NVMe may not be enumerated the instant udevd starts.
DEV=""
tries=5
while [ "$tries" -gt 0 ]; do
    DEV="$(blkid -L config 2>/dev/null || true)"
    if [ -n "$DEV" ]; then break; fi
    tries=$((tries - 1))
    udevadm settle 2>/dev/null || true
    sleep 1
done

if [ -z "$DEV" ]; then
    log "no partition with LABEL=config found, skipping"
    exit 0
fi

log "config partition: $DEV"
mkdir -p /config
mount -t vfat -o defaults "$DEV" /config
log "mounted $DEV at /config"
