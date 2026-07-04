#!/bin/sh
# Arm rootfs A/B redundancy on Jetson when the firmware left it disabled.
#
# A device provisioned by writing the rootfs image straight to disk (e.g. a
# raw NVMe flash) never gets NVIDIA's RootfsRedundancyLevel UEFI variable set —
# that is normally done by tegraflash. Without it the firmware runs single-slot:
# `nvbootctrl -t rootfs set-active-boot-slot` is silently ignored, so every OTA
# installs to the inactive slot, reboots, comes up on the OLD slot, and rolls
# back at commit (running slot != target slot).
#
# This one-shot arms redundancy (identical to `system-status.sh --dual`) and
# reboots once so the firmware picks it up on the next boot. It is idempotent
# and guarded so it can never reboot-loop: once it has attempted the arm, it
# never tries again, even if the arm did not take (that case needs a reflash).
set -eu

GUID="781e084c-a330-417c-b678-38e696380cb9"
EFIVAR_DIR="/sys/firmware/efi/efivars"
REDUNDANCY_VAR="${EFIVAR_DIR}/RootfsRedundancyLevel-${GUID}"
STATE_DIR="/data/wendyos-update"
ATTEMPT_MARKER="${STATE_DIR}/rootfs-redundancy-arm-attempted"

log() { echo "wendyos-tegra-redundancy: $*"; }

# Not a Jetson / no boot control — nothing to do.
command -v nvbootctrl >/dev/null 2>&1 || exit 0

# Already armed: the variable exists. Firmware honors rootfs slot switches;
# leave it alone.
if [ -e "${REDUNDANCY_VAR}" ]; then
    log "rootfs A/B redundancy already armed"
    exit 0
fi

# Only arm when a second rootfs slot actually exists — arming redundancy on a
# genuinely single-slot device would be wrong. APP is slot A, APP_b is slot B.
if [ ! -e /dev/disk/by-partlabel/APP_b ]; then
    log "no APP_b partition; device is single-slot, not arming redundancy"
    exit 0
fi

# Guard against a reboot loop: if we already tried once and the variable is
# still missing, the arm did not take (needs a reflash) — do not try again.
if [ -e "${ATTEMPT_MARKER}" ]; then
    log "already attempted to arm redundancy but it is still disabled; a reflash is required (not retrying)"
    exit 0
fi

log "rootfs A/B redundancy is not armed; arming RootfsRedundancyLevel and rebooting"

# Record the attempt BEFORE writing, on the persistent data partition, so a
# crash between the write and the reboot still counts as one attempt.
mkdir -p "${STATE_DIR}"
: > "${ATTEMPT_MARKER}"
sync

# 4-byte attrs (0x07 = NV+BS+RT) + UINT32 level 1 — the exact payload
# system-status.sh --dual writes. The variable is absent (checked above), so
# there is no immutable flag to clear; the create succeeds directly.
tmp="$(mktemp)"
printf '\x07\x00\x00\x00\x01\x00\x00\x00' > "${tmp}"
if ! cp "${tmp}" "${REDUNDANCY_VAR}" 2>/dev/null; then
    rm -f "${tmp}"
    log "failed to write RootfsRedundancyLevel; leaving the attempt marker so we do not loop"
    exit 0
fi
rm -f "${tmp}"
sync

log "RootfsRedundancyLevel armed; rebooting to activate rootfs A/B redundancy"
exec systemctl --no-block reboot
