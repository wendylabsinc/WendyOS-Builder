#!/bin/sh
# Convert /config from FAT32 to ext4 in place, keeping everything on it.
#
# /config is the provisioning partition. It is FAT32 at flash time because the
# host that images the device -- Windows or macOS -- has to write a seed onto
# it before first boot, and those hosts cannot write ext4. FAT32 costs us two
# things we need afterwards: it has no journal, so a power cut can tear a write
# that nothing repairs, and it has no ownership or permission bits, so anyone
# who can reach the partition can write the file that arms /data encryption.
# ext4 gives both back. The partition keeps its label and its place in the
# table, so nothing that finds /config has to change.
#
# The whole conversion is: stage the contents onto /data, unmount /config,
# mkfs.ext4 over it, mount it back, copy the contents in again. The staging
# copy on /data is what makes a power cut survivable, which is why this runs
# after /data is mounted rather than in early boot.
#
# It refuses, politely and permanently, on a device where encryption is in
# play. The reason is the staging copy: the backup lives on /data, and an
# encrypted /data is unlocked with material kept on /config. Reformatting
# /config there destroys the key to the disk holding the only copy of
# /config's contents. There is no way back from that, so the two refusal rules
# below are absolute.
#
# POSIX sh, no bashisms, `set -u` and no `set -e`: every step is checked where
# it is taken, because the right answer to a failure differs step by step --
# before the format /config is untouched and the run can simply stop, after it
# the staging directory must survive so the next boot finishes the job.
set -u

# Where the partition is mounted, and the two names the staging copy goes
# under. The copy is written to the ".partial" name and renamed to the real one
# only when it is complete, so the rename is what declares the backup valid.
CONFIG_DIR=/config
DATA_DIR=/data
STAGING=/data/.config.pending
STAGING_PARTIAL=/data/.config.pending.partial

# The file that arms /data encryption. Parsed, never sourced: /config is
# writable by anyone who can reach the disk, and sourcing would run its
# contents as root.
CONF="${CONFIG_DIR}/data.conf"

# Free space on /data demanded beyond the size of /config's contents, in 1K
# blocks. /config is 256 MB on every board, so 8 MiB of slack is generous. It
# covers the directory entries the copy creates rather than any growth in the
# data itself.
FREE_SLACK_KB=8192

# What step 6 stopped, so step 10 can put exactly that back and no more.
tee_supplicant_was_active=0
tee_mount_was_active=0

# Whether this device had a TPM before the conversion touched anything. Step 11
# compares it against the state afterwards.
tpm_was_present=0

# Set when the run did its work but something afterwards did not come back.
# The conversion is still reported as done. The exit status carries the fault,
# so the unit shows as failed and the journal says what is missing.
exit_rc=0

# --- output ---------------------------------------------------------------
# Straight to stdout, which is the journal. This service runs well after
# journald is up and after /data is mounted, so there is no reason to write to
# the console the way the /data resolver has to.
log() {
    echo "wendyos-config-convert: $*"
}

# --- reading /proc/mounts -------------------------------------------------
# Is this path a mount point? Read out of /proc/mounts rather than asked of a
# tool, which is how wendyos-data.sh's config_mounted() does it and needs
# nothing installed to answer.
is_mounted() {
    _want=$1
    while read -r _ _mp _; do
        [ "$_mp" = "$_want" ] && return 0
    done < /proc/mounts
    return 1
}

# Source device and filesystem type of a mount point, into mount_source and
# mount_fstype. The LAST entry wins: a second mount over the same point hides
# the first, so the last one is the filesystem that is actually there.
mount_source=""
mount_fstype=""
read_mount() {
    _want=$1
    mount_source=""
    mount_fstype=""
    while read -r _src _mp _fstype _; do
        if [ "$_mp" = "$_want" ]; then
            mount_source=$_src
            mount_fstype=$_fstype
        fi
    done < /proc/mounts
    [ -n "$mount_source" ]
}

# Every mount point still served by $1, as a space-separated list on stdout.
# Returns 0 when there is at least one.
#
# Sources are compared after `readlink -f`, because the same device is spelled
# differently from one mount to the next: /config is mounted by label or by
# partition label, while a bind mount of a directory on it reports the raw
# device node. Only the resolved path is the same string in both.
mounts_on_device() {
    _dev=$1
    _found=""
    while read -r _src _mp _; do
        # Skip everything that is not a path: tmpfs, proc, sysfs and friends
        # name no device, and resolving those strings would resolve them
        # against the current directory.
        case $_src in
            /*)
                ;;
            *)
                continue
                ;;
        esac
        _real=$(readlink -f "$_src" 2>/dev/null) || continue
        [ "$_real" = "$_dev" ] || continue
        _found="$_found $_mp"
    done < /proc/mounts

    [ -n "$_found" ] || return 1
    printf '%s\n' "${_found# }"
}

# --- is /data encrypted? --------------------------------------------------
# The same test wendyos-data.sh makes before it touches anything: resolve what
# /data is mounted from and ask whether that is a device-mapper node. "Is this
# a mapper" is the only question with a correct answer in every state. A
# signature probe is not: on an encrypted board the mount is on the UNLOCKED
# volume, where blkid reports a plain ext4 and the check sails straight past.
data_is_encrypted() {
    if [ -e /dev/mapper/data ]; then
        log "/dev/mapper/data exists, so /data is encrypted"
        return 0
    fi

    if ! read_mount "$DATA_DIR"; then
        return 1
    fi

    _real=$(readlink -f "$mount_source" 2>/dev/null) || return 1
    _base=$(basename "$_real")
    if [ -e "/sys/class/block/$_base/dm/name" ]; then
        log "$DATA_DIR is mounted from $_real, a device-mapper volume, so it is encrypted"
        return 0
    fi

    return 1
}

# --- is the device armed for encryption? ----------------------------------
# DELIBERATELY NOT SHARED with wendyos-data.sh's parser, although it reads the
# same key out of the same file. The two have OPPOSITE safe answers:
#
#   the resolver   an unreadable or malformed file reads as NOT armed, because
#                  it must never encrypt /data by accident
#   this script    an unreadable or malformed file reads as ARMED, because it
#                  must never reformat /config by accident
#
# A shared parser would have to pick one of those and would be wrong for the
# other, in the direction that destroys data. So they stay separate on purpose,
# and this comment is the link between them.
#
# An ABSENT file and an absent key are both "not armed", and that is not a
# softening of the rule: no file means nothing has ever armed the device, which
# is the state every device ships in. The dangerous case is a file that exists
# and says something this parser cannot see, and that is the case that reads as
# armed.
#
# "Armed on anything it cannot parse" is about the VALUE, not about which lines
# count as settings. A line is recognised here exactly as the resolver
# recognises it -- the key, then `=`, with nothing between them -- so the two
# always agree on which lines are settings at all. Writing a looser rule here
# would make this script read `data_encryption = true` as armed while the
# resolver reads the same line as unset, and the device would then refuse the
# conversion for ever over a line that can never encrypt anything.
#
# Leading and trailing blanks and a trailing CR are stripped. /config is FAT
# and may be edited from a Windows host, so a CRLF line is an expected shape
# rather than a corrupt one. Last occurrence wins, as in systemd's own config
# files.
_CR=$(printf '\r')

config_armed() {
    if [ ! -e "$CONF" ]; then
        return 1
    fi

    if [ ! -r "$CONF" ]; then
        log "$CONF exists but cannot be read, which reads as armed"
        return 0
    fi

    _armed=1
    _line=""
    while IFS= read -r _line || [ -n "$_line" ]; do
        while :; do
            case $_line in
                " "*|"	"*)
                    _line=${_line#?}
                    ;;
                *" "|*"	"|*"$_CR")
                    _line=${_line%?}
                    ;;
                *)
                    break
                    ;;
            esac
        done

        case $_line in
            data_encryption=*)
                ;;
            *)
                continue
                ;;
        esac

        # systemd's parse_boolean set, case-insensitive.
        case $(printf '%s' "${_line#*=}" | tr '[:upper:]' '[:lower:]') in
            1|yes|y|true|t|on)
                _armed=0
                ;;
            0|no|n|false|f|off)
                _armed=1
                ;;
            *)
                log "$CONF sets data_encryption to a value this script does not recognise, which reads as armed"
                _armed=0
                ;;
        esac
    done < "$CONF"

    return $_armed
}

# --- space ----------------------------------------------------------------
# Size of /config's contents in 1K blocks, on stdout. -x keeps the count on the
# one filesystem, so a mount placed under /config can never inflate it.
#
# `set --` inside a function sets the FUNCTION's positional parameters, so this
# splits the line into fields without disturbing anything outside.
config_size_kb() {
    _line=$(du -skx "$CONFIG_DIR" 2>/dev/null) || return 1

    # shellcheck disable=SC2086  # splitting the line into fields is the point
    set -- $_line
    [ $# -ge 1 ] || return 1
    printf '%s\n' "$1"
}

# Free space on /data in 1K blocks, on stdout. -P is what fixes the field
# order: filesystem, blocks, used, available, capacity, mount point, one entry
# per line.
data_free_kb() {
    _line=$(df -Pk "$DATA_DIR" 2>/dev/null | tail -n 1) || return 1

    # shellcheck disable=SC2086  # splitting the line into fields is the point
    set -- $_line
    [ $# -ge 4 ] || return 1
    printf '%s\n' "$4"
}

# --- putting back what step 6 stopped -------------------------------------
# Every path that gets past step 6 ends here, success or failure, so no error
# path can forget one of them. Reverse order of the stops: /config first,
# because the bind mount below it has nothing to bind to without it.
restore_stopped() {
    if ! is_mounted "$CONFIG_DIR"; then
        if systemctl start config.mount; then
            log "$CONFIG_DIR is mounted again"
        else
            log "ERROR: could not mount $CONFIG_DIR again -- it stays unmounted for the rest of this boot"
            exit_rc=1
        fi
    fi

    if [ "$tee_mount_was_active" = 1 ]; then
        if systemctl start var-lib-tee.mount; then
            log "var-lib-tee.mount is mounted again"
        else
            log "ERROR: var-lib-tee.mount did not start again, so OP-TEE secure storage is on the rootfs and will not survive an update"
            exit_rc=1
        fi
    fi

    if [ "$tee_supplicant_was_active" = 1 ]; then
        if systemctl start tee-supplicant.service; then
            log "tee-supplicant.service is running again"
        else
            log "ERROR: tee-supplicant.service did not start again, so OP-TEE has no secure storage until the next boot"
            exit_rc=1
        fi
    fi
}

# --- step 1: resume an interrupted run ------------------------------------
# THIS COMES FIRST, BEFORE THE ALREADY-EXT4 CHECK, and the order is not
# cosmetic. A run interrupted after the format leaves the partition ALREADY
# ext4 with nothing on it, so an already-ext4 check placed first would answer
# "nothing to do" and the restore would never run -- the contents would sit in
# the staging directory forever while /config stayed empty.
#
# A run interrupted BEFORE the format also leaves a complete staging directory.
# The restore then writes identical content over itself, which costs a copy and
# changes nothing, and the next boot converts.
#
# $STAGING_PARTIAL is never a resume source. A crash during the copy leaves
# only that name, so a half-copied backup can never be restored over a good
# /config.
log "checking whether $CONFIG_DIR has to be converted from FAT32 to ext4"

if [ -d "$STAGING" ]; then
    log "$STAGING exists, so an earlier run was interrupted: restoring it onto $CONFIG_DIR"

    # The restore writes into $CONFIG_DIR, so the partition has to be there to
    # write to. Without this the copy would land on the rootfs directory the
    # partition mounts over, hiding 256 MB under the next successful mount and
    # filling the rootfs on the way.
    if ! is_mounted "$CONFIG_DIR"; then
        log "ERROR: $CONFIG_DIR is not mounted, so the staged contents stay in $STAGING and are restored on a boot that has it"
        exit 1
    fi

    if ! cp -a "$STAGING/." "$CONFIG_DIR/"; then
        log "ERROR: could not restore $STAGING onto $CONFIG_DIR -- it is left in place and the next boot tries again"
        exit 1
    fi

    sync
    if rm -rf "$STAGING"; then
        log "done: $CONFIG_DIR was restored from $STAGING and the staging directory is gone"
    else
        log "WARN: $CONFIG_DIR was restored but $STAGING could not be removed, so the next boot restores the same contents again"
    fi

    exit 0
fi

# --- step 2: is there a /config to convert? -------------------------------
if ! is_mounted "$CONFIG_DIR"; then
    log "$CONFIG_DIR is not mounted, so there is nothing to convert"
    exit 0
fi

# --- step 3: what is on it already? ---------------------------------------
if ! read_mount "$CONFIG_DIR"; then
    log "ERROR: $CONFIG_DIR is mounted but /proc/mounts names no source for it, so nothing is touched"
    exit 1
fi

CONFIG_SOURCE=$mount_source
CONFIG_FSTYPE=$mount_fstype

CONFIG_DEV=$(readlink -f "$CONFIG_SOURCE" 2>/dev/null)
if [ -z "$CONFIG_DEV" ] || [ ! -b "$CONFIG_DEV" ]; then
    log "ERROR: $CONFIG_DIR is mounted from $CONFIG_SOURCE, which is not a block device, so nothing is touched"
    exit 1
fi

log "$CONFIG_DIR is mounted from $CONFIG_SOURCE ($CONFIG_DEV), filesystem $CONFIG_FSTYPE"
case $CONFIG_FSTYPE in
    ext4)
        log "done: $CONFIG_DIR is already ext4, so there is nothing to convert"
        exit 0
        ;;
    vfat)
        ;;
    *)
        # Only the two filesystems this conversion knows about are safe to act
        # on. Anything else is something nobody here put there, and the one
        # thing we must not do with an unknown filesystem is destroy it.
        log "ERROR: $CONFIG_DIR carries '$CONFIG_FSTYPE', which is neither vfat nor ext4, so nothing is touched"
        exit 1
        ;;
esac

# --- step 4: the two refusal rules ----------------------------------------
# Both mean encryption is in play, and both cut off the route this conversion
# needs. The staging copy goes on /data. If /data is unlocked with material
# kept on /config, reformatting /config destroys the key to the disk holding
# the backup. Refusing is the correct outcome, not a failure, so both exit 0.
#
# THERE IS DELIBERATELY NO CHECK ON /config/tee, and that is the question a
# reader will have, because an earlier version of this rule had one. It made
# sense while that folder appeared only on a device with encryption running.
# It does not now: the OP-TEE bind mount is unconditional on Tegra
# (var-lib-tee.mount, x-systemd.mkdir), so /config/tee is created by systemd on
# every Jetson, encrypted or not -- the rule would refuse the one board family
# this conversion exists for. The OP-TEE files are backed up and restored like
# every other file on the partition.
if data_is_encrypted; then
    log "done: no conversion -- reformatting $CONFIG_DIR could destroy the material that unlocks the disk holding the backup"
    exit 0
fi

if config_armed; then
    log "done: no conversion -- this device is armed for /data encryption, and the conversion must not race it"
    exit 0
fi

# --- step 5: stage the contents onto /data --------------------------------
# /data has to be a real mount. Without this the staging copy lands on the
# rootfs directory /data mounts over, which fills the rootfs and is then hidden
# by the next successful mount. The unit is RequiresMountsFor=/data so this
# should not be reachable. It is checked because the copy is 256 MB and the
# rootfs has nothing like that to spare.
if ! is_mounted "$DATA_DIR"; then
    log "ERROR: $DATA_DIR is not mounted, so there is nowhere to stage the contents of $CONFIG_DIR"
    exit 1
fi

need_kb=$(config_size_kb)
free_kb=$(data_free_kb)
if [ -z "$need_kb" ] || [ -z "$free_kb" ]; then
    log "ERROR: could not measure the size of $CONFIG_DIR or the free space on $DATA_DIR, so nothing is touched"
    exit 1
fi

log "$CONFIG_DIR holds ${need_kb}K and $DATA_DIR has ${free_kb}K free"
if [ "$free_kb" -lt $((need_kb + FREE_SLACK_KB)) ]; then
    log "ERROR: $DATA_DIR has too little free space to stage $CONFIG_DIR, so nothing is touched"
    exit 1
fi

# A leftover partial directory is from a run that died during the copy. It is
# never restored and never trusted, so the only thing to do with it is replace
# it.
if [ -e "$STAGING_PARTIAL" ]; then
    log "removing the leftover $STAGING_PARTIAL from an interrupted copy"
    if ! rm -rf "$STAGING_PARTIAL"; then
        log "ERROR: could not remove $STAGING_PARTIAL, so nothing is touched"
        exit 1
    fi
fi

log "copying $CONFIG_DIR to $STAGING_PARTIAL"
if ! mkdir -p "$STAGING_PARTIAL"; then
    log "ERROR: could not create $STAGING_PARTIAL, so nothing is touched"
    exit 1
fi

if ! cp -a "$CONFIG_DIR/." "$STAGING_PARTIAL/"; then
    log "ERROR: could not copy $CONFIG_DIR to $STAGING_PARTIAL, so nothing is touched"
    rm -rf "$STAGING_PARTIAL"
    exit 1
fi
sync

# The rename is what makes the staging directory valid, and it is the only
# thing that does. Up to this line a crash leaves the partial name, which step
# 1 ignores. After it a crash leaves a complete backup that step 1 restores.
if ! mv "$STAGING_PARTIAL" "$STAGING"; then
    log "ERROR: could not rename $STAGING_PARTIAL to $STAGING, so nothing is touched"
    rm -rf "$STAGING_PARTIAL"
    exit 1
fi

sync
log "the contents of $CONFIG_DIR are staged at $STAGING"

# --- step 6: free the partition -------------------------------------------
# From here on the staging directory is NEVER removed on an error path. It is
# the only copy of /config's contents as soon as the format starts, and leaving
# it is what lets the next boot finish the job.
#
# On Tegra /config/tee is bind-mounted onto /var/lib/tee for OP-TEE, and that
# bind keeps the filesystem mounted after /config itself is unmounted. Measured
# on a Jetson: `umount` on the parent returns success while the device stays
# listed in /proc/mounts against the bind. So the bind has to go first, and
# then the unmount has to be CHECKED rather than believed.
# Was there a TPM before any of this started? Read HERE, before the first stop,
# because stopping the supplicant is what takes it away. Step 11 uses it to
# decide whether the conversion has to end in a reboot.
if [ -e /dev/tpmrm0 ] || [ -e /dev/tpm0 ]; then
    tpm_was_present=1
fi

if systemctl is-active --quiet tee-supplicant.service; then
    tee_supplicant_was_active=1
    log "stopping tee-supplicant.service: it writes to /var/lib/tee, and stopping it keeps anything from landing there during the conversion and being lost"
    if ! systemctl stop tee-supplicant.service; then
        log "ERROR: could not stop tee-supplicant.service, so $CONFIG_DIR is left as it is"
        restore_stopped
        exit 1
    fi
fi

if systemctl is-active --quiet var-lib-tee.mount; then
    tee_mount_was_active=1
    log "stopping var-lib-tee.mount: the bind onto /var/lib/tee holds the $CONFIG_DIR filesystem mounted"
    if ! systemctl stop var-lib-tee.mount; then
        log "ERROR: could not stop var-lib-tee.mount, so $CONFIG_DIR is left as it is"
        restore_stopped
        exit 1
    fi
fi

log "unmounting $CONFIG_DIR"
if ! systemctl stop config.mount; then
    log "ERROR: could not stop config.mount, so $CONFIG_DIR is left as it is"
    restore_stopped
    exit 1
fi

# THE POINT OF THE WHOLE STEP. The unmount above reports success whether or not
# the filesystem actually went away, so without this check a mount nobody
# thought of gets reformatted underneath. It also covers the mounts this script
# does not know by name -- the prebuilt OP-TEE supplicant, or anything a future
# change binds out of /config.
still=$(mounts_on_device "$CONFIG_DEV")
if [ -n "$still" ]; then
    log "ERROR: $CONFIG_DEV is still mounted at: $still -- NOTHING WAS FORMATTED. Find what holds it and remove that mount before this can run"
    restore_stopped
    exit 1
fi

# And nothing is left AT the mount point either. The check above asks about one
# device. This one catches a second filesystem stacked on $CONFIG_DIR, where the
# device read in step 3 is the top of the stack and config.mount only takes away
# the bottom.
if is_mounted "$CONFIG_DIR"; then
    log "ERROR: something is still mounted on $CONFIG_DIR after config.mount stopped -- NOTHING WAS FORMATTED"
    restore_stopped
    exit 1
fi
log "$CONFIG_DEV is no longer mounted anywhere"

# --- step 7: format -------------------------------------------------------
# The label must stay `config`. Every board finds this partition by name:
# the fstab entries use LABEL=config and the Qualcomm config.mount uses the
# partition label, which the format does not touch.
log "formatting $CONFIG_DEV as ext4, label config"
if ! mkfs.ext4 -q -L config "$CONFIG_DEV"; then
    log "ERROR: mkfs.ext4 failed on $CONFIG_DEV. The contents are safe in $STAGING and the next boot tries again"
    restore_stopped
    exit 1
fi

# udev has to re-probe the partition before /dev/disk/by-label/config points at
# the new filesystem. Without the settle the mount below can still be served by
# the link udev made for the FAT filesystem that is now gone.
udevadm settle || log "WARN: udevadm settle failed, so the by-label link may still name the old filesystem"

# Checked only when the link exists at all: the Qualcomm board mounts /config
# by partition label and has no by-label link in its mount path.
if [ -e /dev/disk/by-label/config ]; then
    bylabel=$(readlink -f /dev/disk/by-label/config 2>/dev/null)
    if [ "$bylabel" != "$CONFIG_DEV" ]; then
        log "WARN: /dev/disk/by-label/config points at $bylabel, not $CONFIG_DEV"
    fi
fi

# --- step 8: mount it back ------------------------------------------------
log "mounting the new ext4 filesystem on $CONFIG_DIR"
if ! systemctl start config.mount; then
    log "ERROR: config.mount did not start. The contents are safe in $STAGING and the next boot restores them"
    restore_stopped
    exit 1
fi

if ! read_mount "$CONFIG_DIR" || [ "$mount_fstype" != "ext4" ]; then
    log "ERROR: $CONFIG_DIR is not mounted as ext4 after the format. The contents are safe in $STAGING and the next boot restores them"
    restore_stopped
    exit 1
fi

# And that it is OUR partition. This is the check that makes the by-label
# warning above safe to be only a warning: the mount resolves a name, and if
# that name ever came to point somewhere else, restoring 256 MB of /config onto
# whatever filesystem answered it is the one mistake with no undo.
remounted=$(readlink -f "$mount_source" 2>/dev/null)
if [ "$remounted" != "$CONFIG_DEV" ]; then
    log "ERROR: $CONFIG_DIR is now mounted from $remounted, not $CONFIG_DEV. Nothing is restored, and the contents stay in $STAGING"
    restore_stopped
    exit 1
fi

# --- step 9: restore ------------------------------------------------------
log "restoring the contents of $CONFIG_DIR from $STAGING"
if ! cp -a "$STAGING/." "$CONFIG_DIR/"; then
    log "ERROR: could not restore $STAGING onto $CONFIG_DIR -- it is left in place and the next boot tries again"
    restore_stopped
    exit 1
fi
sync

# Only now, with the contents back on the partition, may the backup go.
if ! rm -rf "$STAGING"; then
    # Not a failure of the conversion, which is complete and correct at this
    # point. The cost is that step 1 restores the same contents again on the
    # next boot, over and over, so it is said plainly rather than hidden.
    log "WARN: $CONFIG_DIR was restored but $STAGING could not be removed, so every later boot restores the same contents again"
fi

# --- step 10: put back what step 6 stopped --------------------------------
restore_stopped

# --- step 11: the verdict -------------------------------------------------
if [ "$exit_rc" = 0 ]; then
    log "done: $CONFIG_DIR is now ext4 on $CONFIG_DEV with its contents restored"
else
    log "done: $CONFIG_DIR is now ext4 on $CONFIG_DEV with its contents restored, but something stopped for the conversion did not come back -- see the errors above"
fi

# On a board with an emulated TPM, the conversion ends in a reboot, and only
# then. Measured on a Jetson 2026-10-07:
#
#   stop the supplicant, start it again        -> the TPM comes back
#   the same, with the bind stopped and started too -> the TPM comes back
#   the same, with /config REFORMATTED between them -> the TPM does NOT come back
#
# So it is not the units. The TEE itself is never restarted by any of this --
# only the userspace supplicant is -- and the fTPM keeps state inside the TEE
# that refers to its own storage. Replace that storage underneath it and the
# state no longer matches, which nothing in userspace can clear: a supplicant
# restart, a reload of tpm_ftpm_tee and a manual modprobe cycle were all tried
# and all failed. A reboot restarts the TEE, and that is the whole reason this
# is a reboot and not a restart.
#
# The test is "was there a TPM, and is it gone now", so a board without one --
# every board in the field today, and every RPi and x86 -- never reaches it.
#
# ONLY ON THE SUCCESS PATH. A failed conversion must not reboot: it would run
# again, fail again and reboot again, and a device in a loop is worse than one
# with no TPM until somebody looks at it. The failure paths leave the unit
# failed and say so, which is visible.
#
# Safe here because the conversion is finished: the contents are back, the
# staging directory is gone and the mounts are up, so an interrupted reboot
# costs nothing and the next boot finds the work done.
if [ "$exit_rc" = 0 ] && [ "$tpm_was_present" = 1 ] &&
   [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
    log "the TPM was present before the conversion and is gone now, and only a reboot brings it back. Rebooting."
    systemctl --no-block reboot
fi

exit "$exit_rc"
