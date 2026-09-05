#!/bin/sh
# First-boot LUKS2 + TPM enrollment for the x86 /data partition.
#
# Runs once, ordered before the boot-time unlock (systemd-cryptsetup@data, via the
# 10-enroll.conf drop-in). It grows the data partition to fill the disk, formats it
# LUKS2, seals a keyslot to the TPM (PCR policy per /etc/data-crypt.conf: a PCR
# list on x86, SRK-only on Jetson), enrols a recovery key, drops the throwaway
# bootstrap slot, and makes the ext4 filesystem. Every later boot it is a fast
# no-op (the partition is already LUKS).
#
# DEFERRED (docs/plans/x86-security.md §13): the no-TPM fallback (D1) is a stub.
# The recovery key goes to the console and to /run/wendyos/data-recovery-key as
# the interim escrow mechanism, never to the journal (which is persisted on /data;
# the rest of this log does go there).
# To generate a fresh recovery key on a running device, see the "Recovery key
# retrieval (wendy CLI contract)" block above step 6.
set -u

DATA=/dev/disk/by-partlabel/data
BK=/run/data-bootstrap.key
INIT_MAP=data_init

# PCR policy for the TPM keyslot. Default PCR 7 (x86 legacy: Secure Boot state).
# /etc/data-crypt.conf (shipped by this recipe) may set TPM_PCRS: a PCR list, or
# empty for SRK-only (no PCR binding) -- Jetson uses empty until secure boot lands.
TPM_PCRS="7"
[ -r /etc/data-crypt.conf ] && . /etc/data-crypt.conf
PCR_ARG=""
[ -n "$TPM_PCRS" ] && PCR_ARG="--tpm2-pcrs=$TPM_PCRS"

# Emit to the console + serial UART only, when present -- never to stdout. This
# service has no StandardOutput override, so stdout is the journal, and the
# journal is persisted on /data (see var-log.mount) and kept for a month. A write
# straight to the device node does not pass through journald.
console() {
    for con in /dev/console /dev/ttyS0; do
        if [ -w "$con" ]; then
            echo "$*" > "$con" 2>/dev/null || true
        fi
    done
}

# Emit to the journal (stdout) and, when present, the console + serial UART.
announce() {
    echo "$*"
    console "$*"
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
# Reads the globals data_base/disk_base resolved right after the device check.
data_fills_disk() {
    disk_sz=$(sysblk "$disk_base" size); disk_sz=${disk_sz:-0}
    d_start=$(sysblk "$data_base" start); d_start=${d_start:-0}
    d_sz=$(sysblk "$data_base" size); d_sz=${d_sz:-0}
    [ "$disk_sz" -gt 0 ] && [ $((d_start + d_sz)) -ge $((disk_sz - END_SLACK)) ]
}

# True when /data carries real user data rather than a fresh partition: every
# install path grows /data on first boot right before formatting it, so
# "grown AND carries a filesystem" stands in for "live".
# KNOWN GAP: a live /data that never reached the disk end reads as fresh here,
# and is then formatted.
data_holds_live_content() {
    data_fills_disk && [ -n "$(lsblk -no FSTYPE "$DATA" 2>/dev/null | head -1)" ]
}

[ -b "$DATA" ] || fail "$DATA not present"

# Resolve the partition/disk early: the idempotence check below needs
# data_fills_disk, not just isLuks.
data_base=$(basename "$(readlink -f "$DATA")")
disk_base=$(basename "$(readlink -f "/sys/class/block/$data_base/..")")
DISK="/dev/$disk_base"
PARTNUM=$(cat "/sys/class/block/$data_base/partition" 2>/dev/null)
[ -n "$PARTNUM" ] || fail "cannot read partition number of $DATA"

# Idempotent -- but "is LUKS" alone is not enough. A reflash recreates the data
# partition at its small stock size WITHOUT zeroing its contents, so the LUKS
# header of the PREVIOUS installation is still at the partition start while its
# key material is gone (TEE/TPM state wiped with the install). An enrolled /data
# always fills the disk (we grow before formatting and fail hard otherwise), so:
# LUKS + fills-disk = done; LUKS + small partition = stale header, re-initialize.
if cryptsetup isLuks "$DATA" 2>/dev/null; then
    if data_fills_disk; then
        echo "data-enroll: $DATA already LUKS2; nothing to do."
        exit 0
    fi
    announce "data-enroll: stale LUKS header from a previous install (partition does not fill the disk); re-initializing"
    # Wipe the stale header NOW: a power loss between the grow below and
    # luksFormat would otherwise leave isLuks + fills-disk, which the
    # idempotence check above mistakes for a completed enrollment. Wiped,
    # an interrupted re-init just retries cleanly next boot.
    wipefs -a "$DATA" || fail "wipefs of the stale LUKS header failed"
fi

# Refuse rather than luksFormat over a provisioned TPM-off installation. Fresh
# installs are unaffected: their stock /data is small, so the predicate is false
# and enrollment proceeds. /data stays unmounted this boot (the LUKS mount path
# expects /dev/mapper/data) but the data survives on disk. Fail CLOSED if lsblk
# is missing: the predicate would read empty and wave a provisioned /data through.
command -v lsblk >/dev/null 2>&1 || fail "lsblk missing -- cannot run the migration guard"
if data_holds_live_content; then
    announce "data-enroll REFUSING to encrypt: $DATA holds a grown filesystem from a previous (TPM-off) installation -- formatting would destroy its data. Leaving it untouched; /data will NOT mount until the device is migrated or re-flashed."
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

# The guard passed, so /data is known fresh (small stock partition, or already
# wiped). Drop any stock filesystem signature (the x86 wic ships /data as an
# empty 512M ext4) BEFORE growing: a power loss between the grow and luksFormat
# would otherwise leave fills-disk + ext4, which the migration guard above
# refuses forever. Failing here retries cleanly next boot (nothing changed yet).
wipefs -a "$DATA" || fail "wipefs of the stock signature failed"

# 1) Grow the data partition to fill the disk BEFORE formatting, so the LUKS
#    container and its ext4 span the whole partition and never need an online
#    resize. GPT only; mirrors grow-data-part.sh.

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
    # too-small /data. Failing here retries cleanly next boot: still not LUKS,
    # and the signature wipe above keeps the migration guard from misfiring.
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

# 5) Seal a keyslot to the TPM. PCR binding per $PCR_ARG (set at top from
#    /etc/data-crypt.conf): a PCR list on x86 (Secure Boot state), SRK-only (no
#    --tpm2-pcrs) on Jetson until secure boot lands.
systemd-cryptenroll --unlock-key-file="$BK" --tpm2-device=auto $PCR_ARG "$DATA" \
    || fail "TPM enrollment failed"

# --- Recovery key retrieval (wendy CLI contract) ---
# The key printed on the console below, and written to
# /run/wendyos/data-recovery-key, is lost at reboot by design: /run is tmpfs and
# it doesn't persist across reboot.
#
# A fresh recovery key can be minted at ANY time on a booted device whose /data is
# unlocked. Run as root:
#
#     systemd-cryptenroll --unlock-tpm2-device=auto --recovery-key \
#         --wipe-slot=recovery /dev/disk/by-partlabel/data
#
# The TPM authorises the change, a new recovery key is printed on stdout, and
# --wipe-slot=recovery removes the PREVIOUS recovery slot. Per
# systemd-cryptenroll(1) the enrollment completes first and the newly added slot is
# always excluded from the wipe, so there is no window with zero recovery keys.
# The new key lands on stdout: do not pipe that command into the journal or a log
# file, for the same reason this script keeps the key off stdout.
#
# This ROTATES: any recovery key issued earlier stops working. That is deliberate,
# so stale printouts cannot stay valid.
#
# The TPM keyslot is untouched -- --wipe-slot=recovery only matches slots unlocked
# by a recovery key. The slot count stays at 2 (tpm2 + recovery) however often this
# is run, so it can never exhaust the 32 keyslots of a LUKS2 header.
#
# Keyslots live in the LUKS2 header on the partition, NOT in the TPM, so this
# consumes no fTPM NV.
#
# UNVERIFIED ON HARDWARE: that --unlock-tpm2-device=auto succeeds while the volume
# is mounted and in use. It operates on the block device and unlocks a keyslot
# independently of the active dm-crypt mapping, so it is expected to work, but it
# has not been run on a device.

# 6) Enrol a recovery key and surface it. REQUIRED, not best-effort: step 7 drops
#    the bootstrap slot right after, so without a recovery key the TPM keyslot is
#    the only way into /data, and any TPM/fTPM state loss makes it permanently
#    unopenable -- a re-flash, a wiped /config/tee, or a changed PCR policy all
#    invalidate that slot. So on failure, log the reason and roll back: this
#    container was luksFormat'ed and mkfs'ed a few lines above and holds no user
#    data, so wiping it costs nothing and makes the next boot re-run the whole
#    enrollment cleanly (not LUKS -> the migration guard passes).
#    INTERIM: the key goes to the console and the /run copy below, never to the
#    journal.
REC_ERR=/run/data-enroll.recovery-err
REC_FILE=/run/wendyos/data-recovery-key
REC="$(systemd-cryptenroll --unlock-key-file="$BK" --recovery-key "$DATA" 2>"$REC_ERR")"
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$REC" ]; then
    announce "data-enroll: recovery-key enrollment failed (exit status $rc), stderr follows:"
    # `|| [ -n "$line" ]` also emits a last line that lacks a trailing newline.
    emitted=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        announce "    | $line"
        emitted=1
    done < "$REC_ERR"
    [ "$emitted" -eq 1 ] || announce "    | (no stderr output)"
    rm -f "$REC_ERR" 2>/dev/null || true
    wipefs -a "$DATA" \
        || announce "data-enroll WARN: rollback wipefs failed -- wipe $DATA manually before the next boot"
    fail "no recovery key enrolled -- refusing to leave /data unlockable by the TPM alone; rolled back, retry next boot"
fi
rm -f "$REC_ERR" 2>/dev/null || true

# Convenience copy on tmpfs, so a provisioning step can read the key without
# scraping the console. Best-effort: the keyslot is enrolled either way, so a
# failure here costs a copy, not access to /data -- record the outcome in
# rec_saved for the banner below and carry on, never roll back. umask 077 in a
# subshell keeps the file 0600 from creation, as with the bootstrap key above.
# luks_uuid tells a reader whether the key still matches the current volume: the
# stale-header re-init path above builds a NEW volume with a NEW recovery key.
rec_saved=1
mkdir -p "${REC_FILE%/*}" 2>/dev/null && (
    umask 077
    {
        echo "# VOLATILE -- /run is tmpfs, so this file is gone at the next reboot."
        echo "# To mint a fresh key, see \"Recovery key retrieval (wendy CLI contract)\""
        echo "# in /usr/sbin/data-enroll.sh."
        echo "# created may be wrong on first boot: the clock is not necessarily set"
        echo "# yet. luks_uuid is the field that identifies the volume."
        echo "recovery_key=$REC"
        echo "luks_uuid=$(cryptsetup luksUUID "$DATA" 2>/dev/null)"
        echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    } > "$REC_FILE"
) || rec_saved=0

announce "=================== /data RECOVERY KEY ==================="
announce "SAVE THIS -- shown once. Unlocks /data if the TPM cannot."
console "  $REC"
announce "  (console only, never the journal -- read $REC_FILE, or mint a fresh key per the retrieval block above step 6)"
announce "INTERIM bring-up only (console + /run, not the journal)."
if [ "$rec_saved" -eq 1 ]; then
    announce "Also written to $REC_FILE -- VOLATILE, lost at the next reboot."
else
    announce "NOT written to $REC_FILE -- the key above is the ONLY copy, save it now."
fi
announce "========================================================="

# 7) Drop the bootstrap slot -- only the TPM and recovery keyslots remain (the
#    recovery key is the fallback). --wipe-slot=password spares the recovery slot
#    (type recovery) and the TPM slot (type tpm2).
systemd-cryptenroll --unlock-key-file="$BK" --wipe-slot=password "$DATA" \
    || announce "data-enroll WARN: could not wipe bootstrap slot"
rm -f "$BK" 2>/dev/null || true

POLICY="SRK-only"
[ -n "$TPM_PCRS" ] && POLICY="PCR $TPM_PCRS"
announce "data-enroll: done. /data is LUKS2 (TPM $POLICY + recovery key)."
