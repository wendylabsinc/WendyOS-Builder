#!/bin/sh
# WendyOS Jetson systemd-boot first-boot enrollment.
#
# Runs once on a freshly flashed Orin to make systemd-boot the primary boot path
# WITHOUT ever leaving the device unbootable:
#   1. copy systemd-bootaa64.efi onto the ESP (both the systemd path and the
#      removable-media fallback \EFI\BOOT\BOOTAA64.efi)
#   2. stage loader/loader.conf + the two A/B loader entries (slot-a+3.conf,
#      slot-b+3.conf) onto the ESP
#   3. copy the kernel + initrd into <ESP>/a/ and <ESP>/b/ (systemd-boot loads
#      the kernel from the ESP, not the ext4 rootfs). A fresh redundant flash has
#      the same rootfs in both slots, so both get the running slot's kernel; the
#      wendyos-update connector refreshes the target slot's kernel on each OTA.
#   4. register a UEFI Boot#### for systemd-boot and put it FIRST in BootOrder,
#      keeping the existing L4TLauncher entry enrolled as a lower-priority
#      fallback (never deleted).
#
# Brick-safety is the whole point: every step that could fail is checked, and if
# BootOrder cannot be set our entry is simply left off — the device still boots
# L4TLauncher exactly as before. Idempotent via a marker; safe to re-run.
set -eu

ESP_MOUNT="/boot/efi"
SRC_DIR="/usr/lib/wendyos-systemdboot"                 # loader.conf + slot-*.conf ship here
SDBOOT_EFI="/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"  # from the systemd-boot package
MARKER="/data/wendyos-update/systemdboot-enrolled"
LOADER='\EFI\systemd\systemd-bootaa64.efi'            # UEFI path (backslashes, on the ESP)
LABEL="WendyOS systemd-boot"

log() { echo "wendyos-systemdboot-firstboot: $*"; }

[ -f "$MARKER" ] && { log "already enrolled; nothing to do"; exit 0; }

# --- 0. Preconditions (fail closed = leave L4TLauncher as-is) --------------
command -v efibootmgr >/dev/null 2>&1 || { log "efibootmgr missing; aborting (device keeps L4TLauncher)"; exit 0; }
mountpoint -q "$ESP_MOUNT" || { log "ESP not mounted at ${ESP_MOUNT}; aborting"; exit 0; }
[ -f "$SDBOOT_EFI" ] || { log "no ${SDBOOT_EFI}; aborting"; exit 0; }
[ -f "${SRC_DIR}/loader.conf" ] || { log "no ${SRC_DIR}/loader.conf; aborting"; exit 0; }

# Resolve the ESP's disk + partition number from the running system (don't
# hardcode nvme0n1p11). partlabel "esp" is set by the NVIDIA flash layout.
ESP_PART="$(readlink -f /dev/disk/by-partlabel/esp 2>/dev/null || true)"
[ -n "$ESP_PART" ] || { log "cannot resolve /dev/disk/by-partlabel/esp; aborting"; exit 0; }
# /dev/nvme0n1p11 -> disk=/dev/nvme0n1 partnum=11 ; /dev/sda11 -> /dev/sda + 11
case "$ESP_PART" in
    *[0-9]p[0-9]*) ESP_DISK="${ESP_PART%p*}"; ESP_PARTNUM="${ESP_PART##*p}" ;;
    *)             ESP_PARTNUM="$(echo "$ESP_PART" | sed 's/.*[^0-9]\([0-9]*\)$/\1/')"
                   ESP_DISK="${ESP_PART%"$ESP_PARTNUM"}" ;;
esac
[ -n "${ESP_DISK:-}" ] && [ -n "${ESP_PARTNUM:-}" ] || { log "cannot parse ESP disk/part from ${ESP_PART}; aborting"; exit 0; }
log "ESP=${ESP_PART} disk=${ESP_DISK} part=${ESP_PARTNUM}"

# --- 1. Stage systemd-boot onto the ESP ------------------------------------
mkdir -p "${ESP_MOUNT}/EFI/systemd" "${ESP_MOUNT}/EFI/BOOT" "${ESP_MOUNT}/loader/entries"
cp -f "$SDBOOT_EFI" "${ESP_MOUNT}/EFI/systemd/systemd-bootaa64.efi"
# Removable-media fallback path: lets the firmware find systemd-boot even if the
# Boot#### entry is lost, and keeps a second escape hatch alongside L4TLauncher.
cp -f "$SDBOOT_EFI" "${ESP_MOUNT}/EFI/BOOT/BOOTAA64.efi"

# --- 2. Stage loader config + the A/B entries (armed with +3 trial counter) -
cp -f "${SRC_DIR}/loader.conf" "${ESP_MOUNT}/loader/loader.conf"
cp -f "${SRC_DIR}/slot-a.conf" "${ESP_MOUNT}/loader/entries/slot-a+3.conf"
cp -f "${SRC_DIR}/slot-b.conf" "${ESP_MOUNT}/loader/entries/slot-b+3.conf"

# --- 3. Copy the kernel + initrd into <ESP>/a/ and <ESP>/b/ ----------------
# systemd-boot reads the kernel from the ESP. On a fresh redundant flash both
# rootfs slots are identical, so seed both ESP slot dirs from the running rootfs;
# the wendyos-update connector refreshes the target slot's copy on each OTA.
KERNEL="/boot/Image"
INITRD="/boot/initrd"
[ -f "$KERNEL" ] || { log "no ${KERNEL} in rootfs; aborting (device keeps L4TLauncher)"; exit 0; }
for slot in a b; do
    mkdir -p "${ESP_MOUNT}/${slot}"
    cp -f "$KERNEL" "${ESP_MOUNT}/${slot}/Image"
    [ -f "$INITRD" ] && cp -f "$INITRD" "${ESP_MOUNT}/${slot}/initrd" || log "no ${INITRD}; slot ${slot} entry must not reference one"
done
sync

# --- 4. Register Boot#### and make it first (L4TLauncher stays as fallback) -
# Idempotent: delete any prior entry with our label before creating a fresh one.
OLD_IDS="$(efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\? ${LABEL}\$/\1/p" || true)"
for id in $OLD_IDS; do efibootmgr -b "$id" -B >/dev/null 2>&1 || true; done

if ! efibootmgr -c -d "$ESP_DISK" -p "$ESP_PARTNUM" -L "$LABEL" -l "$LOADER" >/dev/null 2>&1; then
    log "efibootmgr create failed; device keeps its existing BootOrder (L4TLauncher). NOT marking enrolled."
    exit 0
fi

# Our new entry's id (efibootmgr -c already prepends it to BootOrder). Confirm it
# is present and that BootOrder is non-empty. If either check fails, we still have
# not removed anything, so the device stays bootable.
NEW_ID="$(efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\? ${LABEL}\$/\1/p" | head -n1 || true)"
ORDER="$(efibootmgr | sed -n 's/^BootOrder: //p')"
if [ -z "$NEW_ID" ] || [ -z "$ORDER" ]; then
    log "post-create verification failed (id=${NEW_ID:-none} order=${ORDER:-none}); leaving as-is, NOT marking enrolled"
    exit 0
fi
case ",$ORDER," in
    *",$NEW_ID,"*) : ;;  # already present (efibootmgr -c prepends it)
    *) efibootmgr -o "${NEW_ID},${ORDER}" >/dev/null 2>&1 || { log "could not reorder BootOrder; leaving as-is"; exit 0; } ;;
esac
log "enrolled Boot${NEW_ID} first; BootOrder now: $(efibootmgr | sed -n 's/^BootOrder: //p')"

mkdir -p "$(dirname "$MARKER")"
: >"$MARKER"
log "done"
