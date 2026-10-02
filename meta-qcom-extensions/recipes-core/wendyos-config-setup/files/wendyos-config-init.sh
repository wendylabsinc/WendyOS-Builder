#!/bin/sh
#
# First-boot creation of the FAT32 /config provisioning partition.
#
# qcom-ptool ALLOCATES the config partition but a partitions.conf entry with no
# --filename is left raw, so unlike the wic boards nothing puts a filesystem on
# it. /data has wendyos-data.service for exactly this reason; this is its
# counterpart for /config.
#
# THE ONLY QUESTION IS WHETHER THE PARTITION CARRIES ANYTHING YET -- never what
# it carries, nor who put it there. Flashing rewrites the whole LUN 0 partition
# table, so these sectors are the config partition by construction, whatever
# lived at them under a previous layout. A signature here therefore means an
# earlier boot of this device already made the filesystem, and the only safe
# move is to leave it alone. It may hold a provisioning seed written by
# `wendy os install`.
#
# This is deliberately NOT a test of the filesystem type or the label. An
# earlier version accepted a list of types and reformatted everything else,
# which destroys any filesystem it has not been taught about and reopens the
# same hole each time the filesystem changes. /config is converted from FAT32 to
# ext4 in place in a later release and this script needs no change for it.
#
# Idempotency keys on the PARTITION, never a stamp file: the rootfs is A/B and
# swapped by OTA, so a per-slot stamp would be absent on the other slot and
# would re-format a provisioned device. systemd's ConditionFirstBoot= has the
# same fault. PID 1 derives it from /etc/machine-id, missing or "uninitialized"
# (src/core/main.c:2515-2529), and that file is in the rootfs, so a freshly
# updated slot looks like a first boot.
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

# Blank means no filesystem AND no partition table. Neither probe answers it
# alone, and the same pair is read for the same reason in wendyos-data.sh.
#
# blkid cannot report blankness through its exit status here. On a partition it
# counts the PART_ENTRY_* values it reads out of the parent table, and that
# count is taken before `-s` filters what is printed (util-linux
# misc-utils/blkid.c:551,565,593-594), so a partition with nothing on it exits 0
# and prints nothing. An empty value is the only sign of a blank device.
#
# PTTYPE catches what an empty TYPE cannot: a partition carrying a partition
# table and no filesystem reports no TYPE and a PTTYPE naming the table.
#
# -p probes the device instead of the blkid cache. A cached answer can be stale,
# and this decision reformats a partition.
fs_rc=0
TYPE=$(blkid -p -o value -s TYPE "$DEV" 2>/dev/null) || fs_rc=$?
pt_rc=0
PTTYPE=$(blkid -p -o value -s PTTYPE "$DEV" 2>/dev/null) || pt_rc=$?

# A FAILED probe is not a blank partition. blkid returns 0 or 2 when it has an
# answer and anything else when the probe itself failed, so reading a failure as
# "blank" would format a partition whose contents we could not see. Refusing is
# loud: config.mount Requires= this service, so /config stays unmounted and the
# reason is in the journal.
for rc in "$fs_rc" "$pt_rc"; do
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
        log "ERROR: cannot probe $DEV (blkid exit $rc), so nothing is touched and /config is left unmounted"
        exit 1
    fi
done

if [ -n "$TYPE" ] || [ -n "$PTTYPE" ]; then
    log "$DEV already carries a signature (TYPE='${TYPE:-none}' PTTYPE='${PTTYPE:-none}'); leaving it untouched"
    exit 0
fi

# Nothing at all on the partition, so this is the first boot after a flash.
log "formatting $DEV as FAT32 label=config: it carries no signature at all"
mkfs.vfat -F 32 -n config "$DEV"
log "done"
