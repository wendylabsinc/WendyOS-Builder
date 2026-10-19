#!/bin/sh
#
# First-boot creation of the FAT32 /config provisioning partition.
#
# qcom-ptool ALLOCATES the config partition but a partitions.conf entry with no
# --filename is left raw, so unlike the wic boards nothing puts a filesystem on
# it. /data has wendyos-data.service for exactly this reason; this is its
# counterpart for /config.
#
# Check if the partition content could be ours
# Flashing rewrites the partition table but writes nothing into the config
# partition. So a filesystem the previous image left at these sectors survives
# the flash. The wendy CLI blanks or seeds /config when it flashes, but a hand
# flash with qdl and the build's rawprogram0.xml does not.
#
#  - Blank: format it.
#  - A filesystem bigger than the partition: format it. A filesystem made on
#    this partition always fits it, so this one cannot be ours. It is a leftover
#    from a previous layout, such as the stock rootfs that started at the same
#    sector.
#  - Anything else: keep it. It may be ours: a provisioning seed written by
#    `wendy os install`, or /config after its conversion to ext4.
#
# Known gap: a leftover no bigger than the partition that starts at the same
# sector is kept.
#
# fsck or a failed mount is not used as the test. Neither can tell a leftover
# from our own damaged /config, which must be kept. A leftover that fits the
# partition is intact and mounts anyway, so they catch nothing more than the
# size test.
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

# The config partition on the disk / is mounted from, never one on a second
# disk (99-wendyos-config.rules, data-device recipe). udev makes the link from
# the GPT partition name, so it exists before the partition has a filesystem.
CONFIG_LINK=/dev/wendyos/config
log() { printf '[wendyos-config-init] %s\n' "$*"; }

# Wait briefly for udev to publish the link.
i=0
while [ ! -e "$CONFIG_LINK" ] && [ $i -lt 10 ]; do
    udevadm settle 2>/dev/null || true
    sleep 1
    i=$((i + 1))
done
if [ ! -e "$CONFIG_LINK" ]; then
    log "no $CONFIG_LINK after ${i}s; nothing to do"
    exit 0
fi

DEV=$(readlink -f "$CONFIG_LINK")

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

# FSSIZE is the size the filesystem itself records, in bytes. -p turns on the
# filesystem size info (misc-utils/blkid.c:951-956). Types that record no size,
# and a partition table alone, give an empty value.
fsz_rc=0
FSSIZE=$(blkid -p -o value -s FSSIZE "$DEV" 2>/dev/null) || fsz_rc=$?

# A FAILED probe is not a blank partition. blkid returns 0 or 2 when it has an
# answer and anything else when the probe itself failed, so reading a failure as
# "blank" would format a partition whose contents we could not see. Refusing is
# loud: config.mount Requires= this service, so /config stays unmounted and the
# reason is in the journal.
for rc in "$fs_rc" "$pt_rc" "$fsz_rc"; do
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
        log "ERROR: cannot probe $DEV (blkid exit $rc), so nothing is touched and /config is left unmounted"
        exit 1
    fi
done

if [ -n "$TYPE" ] || [ -n "$PTTYPE" ]; then
    PARTSIZE=
    case "$FSSIZE" in
        ''|*[!0-9]*) ;;
        *)
            # sysfs gives the partition size in 512-byte units, whatever the
            # logical sector size of the disk (UFS here uses 4096-byte sectors).
            # A size we cannot read proves nothing, so the partition is kept.
            PARTSIZE=$(cat "/sys/class/block/$(basename "$DEV")/size" 2>/dev/null) || PARTSIZE=
            case "$PARTSIZE" in
                ''|*[!0-9]*)
                    log "WARN: cannot read the size of $DEV from sysfs ('$PARTSIZE'), so it cannot be proven a leftover"
                    PARTSIZE=
                    ;;
                *)
                    PARTSIZE=$((PARTSIZE * 512))
                    ;;
            esac
            ;;
    esac

    if [ -n "$PARTSIZE" ] && [ "$FSSIZE" -gt "$PARTSIZE" ]; then
        log "$DEV carries a filesystem (TYPE='$TYPE') of $FSSIZE bytes on a $PARTSIZE-byte partition: it cannot have been made here, so it is a leftover from a previous layout; formatting it as FAT32 label=config"
    else
        log "$DEV already carries a signature (TYPE='${TYPE:-none}' PTTYPE='${PTTYPE:-none}' FSSIZE='${FSSIZE:-unknown}' PARTSIZE='${PARTSIZE:-unknown}'); leaving it untouched"
        exit 0
    fi
else
    # Nothing at all on the partition, so this is the first boot after a flash.
    log "formatting $DEV as FAT32 label=config: it carries no signature at all"
fi

mkfs.vfat -F 32 -n config "$DEV"
log "done"
