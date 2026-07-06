#!/bin/sh
# Register a UEFI boot entry for the ESP so capsule-on-disk works on
# raw-installed Jetsons.
#
# A device provisioned by writing the disk image straight to storage (raw
# `wendy os install` / doexternal.sh --sdcard) gets fresh RANDOM partition
# GUIDs (make-sdcard runs `sgdisk --new` without --partition-guid) and never
# updates the UEFI varstore (that lives in QSPI, which a rootfs/NVMe write does
# not touch). So the boot entries a full tegraflash registers are absent, or
# stale (pointing at a previous install's PARTUUIDs). The device then boots via
# the removable-media fallback (\EFI\BOOT\BOOTAA64.EFI on an auto-created
# whole-disk option) with NO registered HD(GPT) boot entry.
#
# NVIDIA's UEFI capsule-on-disk flow (the bootloader/firmware OTA) only runs for
# a *registered* boot device, not the fallback. Without an entry, a capsule OTA
# silently no-ops: the firmware never runs the FMP write, the boot chain never
# switches, and wendyos-update rolls the update back (running slot != target).
# Proven on Orin Nano r39.2 (2026-07-05): registering an HD(GPT) entry made the
# very same capsule fire (UEFI "Update Progress 5%..100%") and switch the chain.
#
# This one-shot registers a proper HD(GPT) entry for the ESP + L4T Launcher when
# a valid one is missing. Idempotent and self-healing: it only acts when no
# entry matches the ESP's CURRENT PARTUUID, so it is safe to run every boot and
# re-registers automatically after each raw install (new PARTUUID). No reboot is
# needed — the entry takes effect on the next boot, in time for any OTA.
set -eu

LOADER='\EFI\BOOT\BOOTAA64.EFI'   # L4T Launcher (the fallback loader on the ESP)
LABEL="WendyOS"
ESP_PARTLABELS="esp UEFI-ESP"     # t264 uses "esp"; t234 layouts use "UEFI-ESP"

log() { echo "tegra-uefi-bootentry: $*"; }

# Belt-and-braces (the unit also gates on ConditionPathExists): a UEFI system
# with efivars and the efibootmgr tool are required.
[ -d /sys/firmware/efi/efivars ] || { log "no efivars; not a UEFI system, skipping"; exit 0; }
command -v efibootmgr >/dev/null 2>&1 || { log "efibootmgr not present; skipping"; exit 0; }

# Resolve the ESP block device from its partition label.
esp_dev=""
for label in $ESP_PARTLABELS; do
    if [ -e "/dev/disk/by-partlabel/$label" ]; then
        esp_dev="$(readlink -f "/dev/disk/by-partlabel/$label")"
        break
    fi
done

[ -n "$esp_dev" ] || { log "no ESP partition (by-partlabel: $ESP_PARTLABELS); skipping"; exit 0; }

# efibootmgr needs the parent disk and the partition NUMBER; the check below
# matches on the ESP's current PARTUUID.
esp_name="$(basename "$esp_dev")"                                   # e.g. nvme0n1p11
disk_name="$(lsblk -ndo PKNAME "$esp_dev" 2>/dev/null || true)"     # e.g. nvme0n1
partnum="$(cat "/sys/class/block/$esp_name/partition" 2>/dev/null || true)"  # e.g. 11
partuuid="$(lsblk -ndo PARTUUID "$esp_dev" 2>/dev/null || true)"

if [ -z "$disk_name" ] || [ -z "$partnum" ] || [ -z "$partuuid" ]; then
    log "could not resolve disk/partnum/partuuid for $esp_dev; skipping"
    exit 0
fi

disk="/dev/$disk_name"

# Already have a boot entry for THIS ESP? Match on the current PARTUUID so a
# stale entry from a previous raw install (different PARTUUID) does not count.
if efibootmgr -v 2>/dev/null | grep -qi "$partuuid"; then
    log "boot entry for ESP $esp_dev (PARTUUID $partuuid) already present; nothing to do"
    exit 0
fi

log "registering UEFI boot entry '$LABEL' -> ${disk} part ${partnum} (PARTUUID $partuuid) loader ${LOADER}"
if efibootmgr -c -d "$disk" -p "$partnum" -L "$LABEL" -l "$LOADER" >/dev/null 2>&1; then
    log "registered; capsule-on-disk OTAs will now be processed on this device"
else
    log "efibootmgr failed to register the boot entry (non-fatal)"
fi

exit 0

