#!/bin/bash
# wendyos-user-credential.sh save|restore
#
# /etc/shadow belongs to the A/B slot, so a newly installed image starts with a
# locked wendy account. This keeps what the device owns in the wendy entry on
# /data and puts it back on the slot that boots next: the password, the day it
# was last changed, and the account expiry. The aging limits stay the image's.

set -u

USER_NAME="wendy"
SHADOW="/etc/shadow"
DATA_MOUNT="${WENDYOS_DATA_MOUNT:-/data}"
STORE_DIR="${DATA_MOUNT}/etc/wendyos-credential"
STORE="${STORE_DIR}/${USER_NAME}"

# Fingerprint of the entry this slot last had in common with the store. It
# tells a change that was never saved (the slot wins) from a new or rolled-back
# slot (the store wins).
SYNCED="/etc/.wendyos-credential-synced"

# Fingerprint of the entry every image shipped before the account was locked.
# That shared password must never become persistent.
LEGACY_SHA256="d1afa97d0a864abe1c57e56fa4fc1a19f7602cbeff30cf3b9b5f67ce583435d4"

log() {
    echo "wendyos-user-credential: $*"
}

fingerprint() {
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
}

# Split a shadow line (name:password:lastchg:min:max:warn:inactive:expire:)
# into E_PASS, E_LAST and E_EXPIRE. Fails on anything that is not a wendy line.
parse_entry() {
    [[ "$1" =~ ^${USER_NAME}:([^:]*):([0-9]{0,10}):[0-9]{0,10}:[0-9]{0,10}:[0-9]{0,10}:[0-9]{0,10}:([0-9]{0,10}):$ ]] || return 1
    E_PASS="${BASH_REMATCH[1]}"
    E_LAST="${BASH_REMATCH[2]}"
    E_EXPIRE="${BASH_REMATCH[3]}"
}

# The part of the wendy shadow line that is kept, in the same shape.
# Returns 1 without a wendy line and 2 for a line that cannot be read.
device_entry() {
    local line
    line=$(grep -m 1 "^${USER_NAME}:" "$SHADOW") || return 1
    parse_entry "$line" || return 2
    printf '%s:%s:%s:::::%s:' "$USER_NAME" "$E_PASS" "$E_LAST" "$E_EXPIRE"
}

# What chpasswd -e accepts (shadow lib/chkhash.c), so a saved entry can always
# be put back. Never empty: an empty field is a login without a password.
valid_field() {
    local hash="${1#!}"
    [ -n "$1" ] || return 1
    if [ -z "$hash" ] || [ "$hash" = "*" ]; then
        return 0
    fi
    [[ "$hash" =~ ^\$y\$[./A-Za-z0-9]+\$[./A-Za-z0-9]{1,86}\$[./A-Za-z0-9]{43}$ ]] ||
        [[ "$hash" =~ ^\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]] ||
        [[ "$hash" =~ ^\$6\$(rounds=[1-9][0-9]{3,8}\$)?[^$:]{1,16}\$[./A-Za-z0-9]{86}$ ]] ||
        [[ "$hash" =~ ^\$5\$(rounds=[1-9][0-9]{3,8}\$)?[^$:]{1,16}\$[./A-Za-z0-9]{43}$ ]]
}

# The old shared password, locked or not.
is_legacy() {
    [ "$(fingerprint "${1#!}")" = "$LEGACY_SHA256" ]
}

# True for a saved entry that may be put back; sets E_PASS, E_LAST, E_EXPIRE.
usable_entry() {
    parse_entry "$1" && valid_field "$E_PASS" &&
        [ "$1" = "${USER_NAME}:${E_PASS}:${E_LAST}:::::${E_EXPIRE}:" ]
}

data_mounted() {
    if ! mountpoint -q "$DATA_MOUNT"; then
        log "${DATA_MOUNT} is not mounted"
        return 1
    fi
}

# Written beside the target and renamed, so a power cut leaves the old content.
write_file() {
    rm -f "$1.tmp" &&
        (umask 077 && printf '%s\n' "$2" > "$1.tmp") &&
        sync "$1.tmp" &&
        mv -f "$1.tmp" "$1" &&
        sync "$(dirname "$1")"
}

# Without the record the next boot only loses the "slot wins" case, so a
# failure here is reported and not fatal.
mark_synced() {
    local mark
    mark=$(fingerprint "$1")
    if [ "$(cat "$SYNCED" 2>/dev/null)" != "$mark" ] && ! write_file "$SYNCED" "$mark"; then
        log "could not record the saved state in ${SYNCED}"
    fi
    return 0
}

restore() {
    local saved current

    data_mounted || return 1

    current=$(device_entry)
    case $? in
        0) ;;
        1) log "no ${USER_NAME} account in ${SHADOW}"; return 0 ;;
        *) log "the ${USER_NAME} entry in ${SHADOW} cannot be read; leaving it"; return 0 ;;
    esac

    if [ -f "$SYNCED" ] && [ "$(cat "$SYNCED" 2>/dev/null)" != "$(fingerprint "$current")" ]; then
        log "this slot has a change that was not saved; keeping it"
        return 0
    fi

    if [ ! -f "$STORE" ]; then
        log "no saved ${USER_NAME} entry"
        return 0
    fi
    if ! IFS= read -r saved < "$STORE" && [ -z "${saved:-}" ] && [ -s "$STORE" ]; then
        log "could not read ${STORE}"
        return 1
    fi

    if ! usable_entry "$saved"; then
        log "ignoring ${STORE}: not a saved ${USER_NAME} entry"
        return 0
    fi
    if is_legacy "$E_PASS"; then
        log "ignoring ${STORE}: it holds the old shared password"
        return 0
    fi
    if [ "$saved" = "$current" ]; then
        mark_synced "$saved"
        return
    fi

    # On stdin: an argument would show in /proc/<pid>/cmdline to every user.
    if ! printf '%s:%s\n' "$USER_NAME" "$E_PASS" | chpasswd -e ||
       ! chage -d "${E_LAST:--1}" -E "${E_EXPIRE:--1}" "$USER_NAME" ||
       [ "$(device_entry)" != "$saved" ]; then
        log "could not restore the ${USER_NAME} entry"
        return 1
    fi
    log "restored the ${USER_NAME} entry"
    mark_synced "$saved"
}

# An entry that may not be kept must not leave an older one behind: it would
# come back on the next slot.
drop_store() {
    rm -f "${STORE}.tmp"
    if [ -e "$STORE" ]; then
        if rm -f "$STORE" && sync "$STORE_DIR"; then
            log "removed the saved ${USER_NAME} entry: $1"
        else
            log "could not remove the saved ${USER_NAME} entry: $1"
            return 1
        fi
    fi
}

save() {
    local current saved

    data_mounted || return 1

    # The watcher, the boot and the shutdown can all run a save.
    if ! install -d -m 0700 "$STORE_DIR" ||
       ! exec 9> "${STORE_DIR}/.lock" ||
       ! flock -w 15 9; then
        log "could not lock ${STORE_DIR}"
        return 1
    fi

    # Read again after each write: the watcher is not armed while this runs.
    for _ in 1 2 3 4 5; do
        current=$(device_entry)
        case $? in
            0) ;;
            1) log "no ${USER_NAME} account in ${SHADOW}"; return 0 ;;
            *) drop_store "the current entry cannot be read"; return ;;
        esac
        parse_entry "$current"
        if ! valid_field "$E_PASS"; then
            drop_store "the current password is empty or not a known hash" && mark_synced "$current"
            return
        fi
        if is_legacy "$E_PASS"; then
            drop_store "the account has the old shared password" && mark_synced "$current"
            return
        fi
        saved=""
        if [ -f "$STORE" ]; then
            IFS= read -r saved < "$STORE" || true
        fi
        if [ "$current" = "$saved" ]; then
            mark_synced "$current"
            return
        fi
        if ! write_file "$STORE" "$current"; then
            drop_store "it could not be updated"
            return 1
        fi
        log "saved the ${USER_NAME} entry"
    done
}

case "${1:-}" in
    save)    save ;;
    restore) restore ;;
    *)
        echo "usage: $0 save|restore" >&2
        exit 2
        ;;
esac
