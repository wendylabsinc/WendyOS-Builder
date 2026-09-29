#!/bin/sh
#
# First-boot creation of the FAT32 /config provisioning partition.
#
# qcom-ptool ALLOCATES the config partition but a partitions.conf entry with no
# --filename is left raw, so unlike the wic boards nothing puts a filesystem on
# it. /data has wendyos-data.service for exactly this reason; this is its
# counterpart for /config.
#
# Idempotency keys on the FILESYSTEM, never a stamp file: the rootfs is A/B and
# swapped by OTA, so a per-slot stamp would be absent on the other slot and could
# trigger a re-format that wipes provisioning data.
set -eu

BYLABEL=/dev/disk/by-partlabel/config
log() { printf '[wendyos-config-init] %s\n' "$*"; }

# Wait briefly for udev to publish the by-partlabel link.
i=0
while [ ! -e "$BYLABEL" ] && [ $i -lt 10 ]; do
    udevadm settle 2>/dev/null || true
    sleep 1
    i=$((i + 1))
done
if [ ! -e "$BYLABEL" ]; then
    log "no $BYLABEL after ${i}s; nothing to do"
    exit 0
fi

DEV=$(readlink -f "$BYLABEL")

# Already a filesystem we recognise, labelled "config"? Then leave it entirely
# alone -- it may hold a provisioning seed written by `wendy os install`.
#
# ext4 is accepted as well as vfat because /config is converted from FAT32 to
# ext4 in place later. Without this, a board that had been converted and then
# rolled back by A/B to a rootfs older than the conversion would fall through to
# the mkfs below and lose /config on every boot -- config.mount Requires= this
# service, so it runs before the mount. Accepting ext4 must therefore ship in
# the same release as the tolerant `Type=auto` mount entry, ahead of the
# conversion itself, for the same reason that entry does. Inert until the first
# board converts.
TYPE=$(blkid -o value -s TYPE "$DEV" 2>/dev/null || true)
LABEL=$(blkid -o value -s LABEL "$DEV" 2>/dev/null || true)
case "${TYPE}:${LABEL}" in
    vfat:config|ext4:config)
        log "$DEV already $TYPE/config; leaving untouched"
        exit 0
        ;;
esac

# Anything else -- unformatted, or a stale filesystem left at the same LBA by a
# previous layout (this board ships with Qualcomm Linux, whose 'persist'
# partition starts at the same sector) -- gets a fresh FAT32.
log "formatting $DEV as FAT32 label=config (was TYPE='${TYPE:-none}' LABEL='${LABEL:-none}')"
mkfs.vfat -F 32 -n config "$DEV"
log "done"
