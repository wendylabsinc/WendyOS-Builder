#!/bin/sh
# WendyOS Jetson GRUB2 first-boot enrollment.
#
# Runs once on a freshly flashed Orin to make our GRUB2 the primary boot path
# WITHOUT ever leaving the device unbootable:
#   1. copy grubaa64.efi + grub.cfg (+ grubenv if absent) onto the ESP, into the
#      GRUB prefix dir EFI/wendyos (matches EFIDIR / the grubenv connector path)
#   2. register a UEFI Boot#### for grubaa64.efi and put it FIRST in BootOrder,
#      keeping the existing L4TLauncher entry enrolled as a lower-priority
#      fallback (never deleted).
#
# Brick-safety is the whole point: every step that could fail is checked, and if
# BootOrder cannot be set our entry is simply left off — the device still boots
# L4TLauncher exactly as before. Idempotent via a marker; safe to re-run.
set -eu

ESP_MOUNT="/boot/efi"
ESP_DIR="${ESP_MOUNT}/EFI/wendyos"        # GRUB prefix (matches EFIDIR)
SRC_DIR="/usr/lib/wendyos-grub"           # image ships grubaa64.efi + grub.cfg + grubenv here
MARKER="/data/wendyos-update/grub-enrolled"
LOADER='\EFI\wendyos\grubaa64.efi'        # UEFI path (backslashes, on the ESP)
LABEL="WendyOS GRUB"

log() { echo "wendyos-grub-firstboot: $*"; }

[ -f "$MARKER" ] && { log "already enrolled; nothing to do"; exit 0; }

# --- 0. Preconditions (fail closed = leave L4TLauncher as-is) --------------
command -v efibootmgr >/dev/null 2>&1 || { log "efibootmgr missing; aborting (device keeps L4TLauncher)"; exit 0; }
mountpoint -q "$ESP_MOUNT" || { log "ESP not mounted at ${ESP_MOUNT}; aborting"; exit 0; }
[ -f "${SRC_DIR}/grubaa64.efi" ] || { log "no ${SRC_DIR}/grubaa64.efi; aborting"; exit 0; }

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

# --- 1. Stage grubaa64.efi + grub.cfg (+ grubenv if virgin) onto the ESP ----
mkdir -p "$ESP_DIR"
cp -f "${SRC_DIR}/grubaa64.efi" "${ESP_DIR}/grubaa64.efi"
cp -f "${SRC_DIR}/grub.cfg"     "${ESP_DIR}/grub.cfg"
# Only seed the grubenv if the ESP has none: a re-run (or a re-flash that kept
# the ESP) must never reset live A/B state. GRUB save_env rewrites this file
# in place, so it must stay the exact 1024-byte block created at build time.
[ -f "${ESP_DIR}/grubenv" ] || cp -f "${SRC_DIR}/grubenv" "${ESP_DIR}/grubenv"
sync

# --- 2. Register Boot#### and make it first (L4TLauncher stays as fallback) -
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
