#!/bin/bash
# wendyos-user-credential.sh save|restore|watch
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
# Two lines: the entry, then a token that every write replaces.
STORE="${STORE_DIR}/${USER_NAME}"

# "<fingerprint of this slot's entry> <store token>" from this slot's last sync.
# A token that has changed means another slot, booted later, saved since: its
# entry is newer. "removed.<token>" names the marker this slot left in place
# of a store it had to remove.
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
    parse_entry "$1" && valid_field "$E_PASS" && ! is_legacy "$E_PASS" &&
        [ "$1" = "${USER_NAME}:${E_PASS}:${E_LAST}:::::${E_EXPIRE}:" ]
}

# The stored form of a slot entry: the password is replaced by "*" when it may
# not be kept, so no other slot goes back to an older password.
kept_entry() {
    parse_entry "$1" || return 1
    if ! valid_field "$E_PASS" || is_legacy "$E_PASS"; then
        E_PASS="*"
    fi
    printf '%s:%s:%s:::::%s:' "$USER_NAME" "$E_PASS" "$E_LAST" "$E_EXPIRE"
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

# Sets S_ENTRY and S_TOKEN from the store. Fails only when it cannot be opened.
read_store() {
    S_ENTRY=""
    S_TOKEN=""
    { IFS= read -r S_ENTRY || true; IFS= read -r S_TOKEN || true; } < "$STORE"
}

# Sets REC_SLOT and REC_TOKEN from this slot's record, empty without one.
read_record() {
    REC_SLOT=""
    REC_TOKEN=""
    if [ -f "$SYNCED" ]; then
        read -r REC_SLOT REC_TOKEN < "$SYNCED" 2>/dev/null || true
    fi
}

# A record that cannot be written makes the next boot apply the store, which
# by then holds this slot's own entry, so a failure here is not fatal.
mark_synced() {
    local mark
    mark="$(fingerprint "$1") $2"
    if [ "$(cat "$SYNCED" 2>/dev/null)" != "$mark" ] && ! write_file "$SYNCED" "$mark"; then
        log "could not record the saved state in ${SYNCED}"
    fi
    return 0
}

# This slot has saved before, so a store that is gone or unreadable was removed
# by a failed save on another slot or by hand: keep no password from this slot.
fail_closed() {
    log "$1; removing this slot's ${USER_NAME} password"
    if ! printf '%s:*\n' "$USER_NAME" | chpasswd -e; then
        log "could not remove the ${USER_NAME} password"
        return 1
    fi
    rm -f "$SYNCED"
}

restore() {
    local current

    data_mounted || return 1

    current=$(device_entry)
    case $? in
        0) ;;
        1) log "no ${USER_NAME} account in ${SHADOW}"; return 0 ;;
        *) log "the ${USER_NAME} entry in ${SHADOW} cannot be read; leaving it"; return 0 ;;
    esac
    read_record

    if [ ! -f "$STORE" ]; then
        if [[ "$REC_TOKEN" == removed.* ]] && [ -e "${STORE}.${REC_TOKEN}" ]; then
            log "this slot removed the saved ${USER_NAME} entry; keeping its own until it saves"
            return 0
        fi
        if [ -n "$REC_SLOT" ]; then
            fail_closed "the saved ${USER_NAME} entry is gone"
            return
        fi
        log "no saved ${USER_NAME} entry"
        return 0
    fi
    if ! read_store; then
        if [ -n "$REC_SLOT" ]; then
            fail_closed "the saved ${USER_NAME} entry cannot be read"
            return
        fi
        log "could not read ${STORE}"
        return 1
    fi
    if ! usable_entry "$S_ENTRY"; then
        if [ -n "$REC_SLOT" ]; then
            fail_closed "the saved ${USER_NAME} entry cannot be used"
            return
        fi
        log "ignoring ${STORE}: not a saved ${USER_NAME} entry"
        return 0
    fi

    # Nobody saved since this slot's last sync: anything new on this slot is
    # its own change, which the save after this keeps.
    if [ -n "$REC_TOKEN" ] && [ "$REC_TOKEN" = "$S_TOKEN" ]; then
        if [ "$REC_SLOT" != "$(fingerprint "$current")" ]; then
            log "this slot has a change that was not saved; keeping it"
        fi
        return 0
    fi
    if [ "$S_ENTRY" = "$current" ]; then
        mark_synced "$current" "$S_TOKEN"
        return 0
    fi

    # Forget the record first, so a restore that stops halfway is retried at
    # the next boot instead of being kept as an unsaved change.
    if [ -e "$SYNCED" ] && ! { rm -f "$SYNCED" && sync "$(dirname "$SYNCED")"; }; then
        log "could not clear ${SYNCED}"
        return 1
    fi
    # Disabled until every field is in place, so a later failure fails closed.
    if ! chage -E 1 "$USER_NAME"; then
        log "could not disable the ${USER_NAME} account to restore it; leaving it as it is for this boot"
        return 1
    fi
    # The password goes on stdin: an argument shows in /proc/<pid>/cmdline.
    if ! printf '%s:%s\n' "$USER_NAME" "$E_PASS" | chpasswd -e ||
       ! chage -d "${E_LAST:--1}" -E "${E_EXPIRE:--1}" "$USER_NAME" ||
       [ "$(device_entry)" != "$S_ENTRY" ]; then
        log "could not restore the ${USER_NAME} entry; the account stays disabled for this boot"
        return 1
    fi
    log "restored the ${USER_NAME} entry"
    mark_synced "$S_ENTRY" "$S_TOKEN"
}

# Every slot that saved before treats a missing store as removed and keeps no
# password. The store becomes a marker named after a new token, which only this
# slot records, so this slot alone keeps its own entry. A rename needs no free
# space, and emptying the marker only frees it.
drop_store() {
    local mark
    mark="removed.$(cat /proc/sys/kernel/random/uuid)"
    rm -f "${STORE}.tmp"
    if [ -e "$STORE" ]; then
        mv -f "$STORE" "${STORE}.${mark}" && : > "${STORE}.${mark}"
    else
        : > "${STORE}.${mark}"
    fi
    if [ ! -e "${STORE}.${mark}" ] || [ -e "$STORE" ]; then
        log "could not remove the saved ${USER_NAME} entry: $1"
        return 1
    fi
    # Only the latest removal counts: an older marker, from any slot, would let
    # that slot keep an entry older than this one.
    remove_marks "${STORE}.${mark}"
    log "removed the saved ${USER_NAME} entry: $1"
    mark_synced "$2" "$mark"
}

# Removes every removal marker except $1, and makes that stick.
remove_marks() {
    local m
    for m in "${STORE}".removed.*; do
        [ "$m" = "${1:-}" ] || rm -f "$m"
    done
    sync "$STORE_DIR"
}

save() {
    local current kept token

    data_mounted || return 1

    # The watcher, the boot and the shutdown can all run a save.
    if ! install -d -m 0700 "$STORE_DIR" ||
       ! exec 9> "${STORE_DIR}/.lock" ||
       ! flock -w 15 9; then
        log "could not lock ${STORE_DIR}"
        return 1
    fi

    # Read again after each write: the entry can change while this runs.
    for _ in 1 2 3 4 5; do
        current=$(device_entry)
        case $? in
            0) ;;
            1) log "no ${USER_NAME} account in ${SHADOW}"; return 0 ;;
            *) drop_store "the current entry cannot be read" ""; return ;;
        esac
        kept=$(kept_entry "$current")
        if [ "$kept" != "$current" ]; then
            log "not keeping the ${USER_NAME} password: it is empty, the old shared one, or not a supported hash"
        fi
        if [ -f "$STORE" ]; then
            read_store || { log "could not read ${STORE}"; return 1; }
            if [ "$kept" = "$S_ENTRY" ] && [ -n "$S_TOKEN" ]; then
                mark_synced "$current" "$S_TOKEN"
                return 0
            fi
        fi
        token=$(cat /proc/sys/kernel/random/uuid)
        if ! write_file "$STORE" "$kept"$'\n'"$token"; then
            drop_store "it could not be updated" "$current"
            return 1
        fi
        # A saved entry replaces every removal any slot recorded.
        remove_marks
        log "saved the ${USER_NAME} entry"
    done
}

# Saves whenever /etc/shadow's metadata differs from the last saved look. It
# compares state, not change events, so a change made during a save is not
# missed, and a failed save is retried until it works.
watch() {
    local seen="" now retry=0
    while :; do
        now=$(stat -c '%d %i %y %z %s' "$SHADOW" 2>/dev/null)
        if [ "$now" != "$seen" ]; then
            # Its own process, so the store lock is released between saves.
            if timeout 120 "$0" save; then
                seen=$now
                retry=0
            else
                # Back off up to a minute, so a full /data is not hammered.
                retry=$(( retry ? (retry * 2 > 60 ? 60 : retry * 2) : 2 ))
                sleep "$retry"
                continue
            fi
        fi
        sleep "${WENDYOS_CREDENTIAL_INTERVAL:-2}"
    done
}

case "${1:-}" in
    save)    save ;;
    restore) restore ;;
    watch)   watch ;;
    *)
        echo "usage: $0 save|restore|watch" >&2
        exit 2
        ;;
esac
