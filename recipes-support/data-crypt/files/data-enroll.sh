#!/bin/sh
# First-boot LUKS2 + TPM enrollment for the x86 /data partition.
#
# Runs once, ordered before the boot-time unlock (systemd-cryptsetup@data, via the
# 10-enroll.conf drop-in). It grows the data partition to fill the disk, formats it
# LUKS2, seals a keyslot to the TPM (PCR 7), enrols a recovery key, drops the
# throwaway bootstrap slot, and makes the ext4 filesystem. Every later boot it is a
# fast no-op (the partition is already LUKS). See docs/plans/x86-security.md.
#
# DEFERRED (docs/plans/x86-security.md §13): the no-TPM fallback (D1) is a stub, and
# the recovery key is printed to the journal + console for bring-up only -- the
# production escrow path (D3) is undecided. Do NOT ship as-is.
set -u

DATA=/dev/disk/by-partlabel/data
BK=/run/data-bootstrap.key
INIT_MAP=data_init

# Emit to the journal (stdout) and, when present, the console + serial UART.
announce() {
    echo "$*"
    for con in /dev/console /dev/ttyS0; do
        if [ -w "$con" ]; then
            echo "$*" > "$con" 2>/dev/null || true
        fi
    done
}

fail() {
    announce "data-enroll ERROR: $*"
    rm -f "$BK" 2>/dev/null || true
    exit 1
}

# Trailing slack (~4 MiB) tolerated as "fills the disk", mirroring grow-data-part.
END_SLACK=8192

sysblk() { cat "/sys/class/block/$1/$2" 2>/dev/null; }

# True when the kernel sees the /data PARTITION reaching the disk end within slack.
# Reads the globals data_base/disk_base set in the grow section below.
data_fills_disk() {
    disk_sz=$(sysblk "$disk_base" size); disk_sz=${disk_sz:-0}
    d_start=$(sysblk "$data_base" start); d_start=${d_start:-0}
    d_sz=$(sysblk "$data_base" size); d_sz=${d_sz:-0}
    [ "$disk_sz" -gt 0 ] && [ $((d_start + d_sz)) -ge $((disk_sz - END_SLACK)) ]
}

[ -b "$DATA" ] || fail "$DATA not present"

# Idempotent: once the partition is LUKS, enrollment is done -- the crypttab unlock
# (systemd-cryptsetup@data) takes over from here.
if cryptsetup isLuks "$DATA" 2>/dev/null; then
    echo "data-enroll: $DATA already LUKS2; nothing to do."
    exit 0
fi

# No TPM -> DEFERRED fallback D1. This hardware has a confirmed TPM; if one is ever
# absent, do not brick first boot -- leave /data unformatted and warn. Proper
# fallback (passphrase-only vs plaintext) is still to be decided.
if [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
    announce "data-enroll WARNING: no TPM found -- leaving /data UNENCRYPTED (D1 TBD)."
    exit 0
fi

announce "data-enroll: first-boot LUKS2 + TPM enrollment of $DATA"

# 1) Grow the data partition to fill the disk BEFORE formatting, so the LUKS
#    container and its ext4 span the whole partition and never need an online
#    resize. x86 GPT only; mirrors grow-data-part.sh, kept x86-local (§13/D4).
data_base=$(basename "$(readlink -f "$DATA")")
disk_base=$(basename "$(readlink -f "/sys/class/block/$data_base/..")")
DISK="/dev/$disk_base"
PARTNUM=$(cat "/sys/class/block/$data_base/partition" 2>/dev/null)
[ -n "$PARTNUM" ] || fail "cannot read partition number of $DATA"

if data_fills_disk; then
    announce "data-enroll: /data partition already fills $DISK; no grow needed"
else
    # Relocate the GPT backup header to the real disk end (stranded at the wic's
    # end after flashing to a larger disk), else parted resizepart 100% fails.
    announce "data-enroll: relocating GPT backup header to end of $DISK"
    sgdisk -e "$DISK" || announce "data-enroll WARN: sgdisk -e failed"
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle -t 10 2>/dev/null || true

    announce "data-enroll: growing partition #$PARTNUM on $DISK to fill the disk"
    parted -s "$DISK" resizepart "$PARTNUM" 100% || announce "data-enroll WARN: resizepart failed"
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle -t 10 2>/dev/null || true

    # Guard: refuse to format a partition that did not actually grow (e.g. the
    # kernel did not pick up the new table), so we never luksFormat/mkfs a
    # too-small /data. Failing here retries cleanly next boot (still not LUKS).
    data_fills_disk || fail "grew /data but the kernel did not pick up the new size (retry next boot)"
fi

# 2) Throwaway bootstrap key (tmpfs, 0600) to author the volume.
(umask 077; head -c 64 /dev/urandom > "$BK") || fail "cannot create bootstrap key"

# 3) Format LUKS2 with the bootstrap key.
cryptsetup luksFormat --type luks2 --batch-mode --key-file="$BK" "$DATA" \
    || fail "luksFormat failed"

# 4) Make the ext4 filesystem inside (open via bootstrap key, mkfs, close).
cryptsetup open --key-file="$BK" "$DATA" "$INIT_MAP" || fail "open (bootstrap) failed"
mkfs.ext4 -q -L data "/dev/mapper/$INIT_MAP" || { cryptsetup close "$INIT_MAP"; fail "mkfs.ext4 failed"; }
cryptsetup close "$INIT_MAP" || true

# 5) Seal a keyslot to the TPM, bound to PCR 7 (Secure Boot state -- OTA-stable).
systemd-cryptenroll --unlock-key-file="$BK" --tpm2-device=auto --tpm2-pcrs=7 "$DATA" \
    || fail "TPM enrollment failed"

# 6) Enrol a recovery key and surface it. INTERIM: journal + console only, escrow
#    is undecided (D3). This is the safety net if the TPM ever cannot unseal.
REC="$(systemd-cryptenroll --unlock-key-file="$BK" --recovery-key "$DATA" 2>/dev/null)"
if [ -n "$REC" ]; then
    announce "=================== /data RECOVERY KEY ==================="
    announce "SAVE THIS -- shown once. Unlocks /data if the TPM cannot."
    announce "  $REC"
    announce "INTERIM bring-up only (journal + console). Escrow TBD (D3)."
    announce "========================================================="
else
    announce "data-enroll WARNING: recovery-key enrollment produced no key"
fi

# 7) Drop the bootstrap slot -- only the TPM and recovery keyslots remain (the
#    recovery key is the fallback). --wipe-slot=password spares the recovery slot
#    (type recovery) and the TPM slot (type tpm2).
systemd-cryptenroll --unlock-key-file="$BK" --wipe-slot=password "$DATA" \
    || announce "data-enroll WARN: could not wipe bootstrap slot"
rm -f "$BK" 2>/dev/null || true

announce "data-enroll: done. /data is LUKS2 (TPM PCR 7 + recovery key)."
