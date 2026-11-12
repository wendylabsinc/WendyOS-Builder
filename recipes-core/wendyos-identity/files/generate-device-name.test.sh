#!/usr/bin/env bash
# Tests for generate-device-name.sh — plain bash, no framework, same shape as
# update-mdns-uuid.test.sh.
#
# First boot must take the name given at flash time (wendy.conf on /config),
# else gadget-setup bakes a random placeholder into the USB product string.
# Every other input — no file, no name, an invalid name, junk — must still end
# in a valid generated name and exit 0, because this runs during boot.
#
# Fully isolated: all paths point into a temp tree and logger is stubbed.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_DIR}/generate-device-name.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/bin/logger"
chmod +x "${WORK}/bin/logger"

# run CONF_CONTENT [EXISTING_NAME] — "" means an absent file; sets NAME and RC.
run() {
    rm -rf "${WORK:?}/etc" "${WORK:?}/config"
    mkdir -p "${WORK}/etc" "${WORK}/config"
    [ -n "$1" ] && printf '%b' "$1" > "${WORK}/config/wendy.conf"
    [ -n "${2:-}" ] && printf '%s\n' "$2" > "${WORK}/etc/device-name"
    PATH="${WORK}/bin:${PATH}" \
        DEVICE_NAME_FILE="${WORK}/etc/device-name" \
        WENDY_CONF="${WORK}/config/wendy.conf" \
        ADJECTIVES_FILE="${SCRIPT_DIR}/adjectives.txt" \
        NOUNS_FILE="${SCRIPT_DIR}/nouns.txt" \
        bash "$SCRIPT" >/dev/null 2>&1
    RC=$?
    NAME=$(cat "${WORK}/etc/device-name" 2>/dev/null)
}

valid() { [[ "$1" =~ ^[a-z][a-z0-9-]{1,53}[a-z0-9]$ ]]; }

# expect DESC WANT — WANT "" means "any valid generated name".
expect() {
    if [ "$RC" -ne 0 ]; then bad "$1: exit $RC"; return; fi
    if [ -n "$2" ]; then
        if [ "$NAME" = "$2" ]; then ok "$1"; else bad "$1: got '$NAME', want '$2'"; fi
    elif valid "$NAME"; then
        ok "$1 (generated '$NAME')"
    else
        bad "$1: invalid name '$NAME'"
    fi
}

# The CLI's format (marshalWendyConf in the agent).
run '[wifi]\nssid = home\n\n[device]\nname = hackathon-device-19\n'
expect "flash-time name is used" "hackathon-device-19"

run '[device]\r\n; comment\r\n  name=lab-pi \r\nname = lab-pi-2\r\n'
expect "CRLF, comments, no spaces, last duplicate wins" "lab-pi-2"

run ''
expect "no wendy.conf generates a name" ""

run '[wifi]\nssid = home\n'
expect "wendy.conf without [device] generates a name" ""

run '[device]\nname =\n'
expect "empty name generates a name" ""

run 'name = outside-section\n'
expect "name outside a section is ignored" ""

run '[wifi]\nname = wifi-section\n'
expect "name in another section is ignored" ""

for n in 'Hackathon' 'ab' 'x-' '9lives' 'has space' 'a;rm -rf' "$(printf 'a%.0s' {1..56})"; do
    run "[device]\nname = $n\n"
    if [ "$NAME" = "$n" ]; then bad "invalid name '$n' was used"; else expect "invalid name '$n' rejected" ""; fi
done

run '\x00\xff\xfe[device\nname = = =\n\x1b[31m'
expect "binary junk generates a name" ""

run '[device]\nname = from-conf\n' 'already-named'
expect "existing valid device-name is kept" "already-named"

# Unreadable: wendy.conf is a directory.
rm -rf "${WORK:?}/etc" "${WORK:?}/config"; mkdir -p "${WORK}/etc" "${WORK}/config/wendy.conf"
PATH="${WORK}/bin:${PATH}" DEVICE_NAME_FILE="${WORK}/etc/device-name" \
    WENDY_CONF="${WORK}/config/wendy.conf" ADJECTIVES_FILE="${SCRIPT_DIR}/adjectives.txt" \
    NOUNS_FILE="${SCRIPT_DIR}/nouns.txt" bash "$SCRIPT" >/dev/null 2>&1
RC=$?; NAME=$(cat "${WORK}/etc/device-name" 2>/dev/null)
expect "unreadable wendy.conf generates a name" ""

echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
