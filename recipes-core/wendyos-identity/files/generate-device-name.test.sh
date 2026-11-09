#!/usr/bin/env bash
# Tests for generate-device-name.sh — plain bash, no framework, same shape as
# update-mdns-uuid.test.sh.
#
# Covers the first-boot name: the name chosen with `wendy install` (the
# [device] section of /config/wendy.conf) is used from the first boot instead
# of a random one, parsed the way the agent parses it; anything unusable falls
# back to the random name, and an existing device-name is never replaced.
#
# Fully isolated: every path points into a temp tree.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_DIR}/generate-device-name.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

printf 'brave\n' > "${WORK}/adjectives.txt"
printf 'dolphin\n' > "${WORK}/nouns.txt"

# run <case-dir>: run the generator against <case-dir> and print the name.
run() {
    local dir=$1
    DEVICE_NAME_FILE="${dir}/etc/device-name" \
    ADJECTIVES_FILE="${WORK}/adjectives.txt" \
    NOUNS_FILE="${WORK}/nouns.txt" \
    WENDY_CONF="${dir}/config/wendy.conf" \
        bash "${SCRIPT}" >/dev/null 2>&1 || return 1
    tr -d '[:space:]' < "${dir}/etc/device-name"
}

# newcase <name> [wendy.conf content]: a fresh tree, optionally with a wendy.conf.
newcase() {
    local dir="${WORK}/$1"
    mkdir -p "${dir}/etc" "${dir}/config"
    if [ $# -ge 2 ]; then
        printf '%b' "$2" > "${dir}/config/wendy.conf"
    fi
    echo "${dir}"
}

expect() {
    local label=$1 dir=$2 want=$3 got
    got=$(run "${dir}") || { bad "${label}: generator failed"; return; }
    if [ "${got}" = "${want}" ]; then ok "${label}"; else bad "${label}: got '${got}', want '${want}'"; fi
}

conf='[wifi]\nssid = Home\npassword = hunter2-secret\n\n[device]\nname = lab-pi\n'

d=$(newcase install-name "${conf}")
expect "uses the name chosen at install" "${d}" "lab-pi"

d=$(newcase no-conf)
expect "no wendy.conf falls back to the random name" "${d}" "brave-dolphin"

d=$(newcase no-device-section '[wifi]\nssid = Home\npassword = x\n')
expect "wendy.conf without a name falls back" "${d}" "brave-dolphin"

d=$(newcase crlf-comments '# written on Windows\r\n[device]\r\n; note\r\n  name   =   lab-pi  \r\n')
expect "CRLF, comments and padding are tolerated" "${d}" "lab-pi"

d=$(newcase last-wins '[device]\nname = first-pi\nname = second-pi\n')
expect "last name wins, as in the agent" "${d}" "second-pi"

d=$(newcase other-section '[wifi]\nname = not-a-device\n[device]\nid = x\n')
expect "a name key outside [device] is ignored" "${d}" "brave-dolphin"

for invalid in 'Lab-Pi' 'pi' 'lab-pi-' '1lab' 'lab_pi' 'lab pi' "$(printf 'a%.0s' $(seq 1 56))"; do
    d=$(newcase "invalid-${RANDOM}" "[device]\nname = ${invalid}\n")
    expect "invalid name '${invalid:0:20}' falls back" "${d}" "brave-dolphin"
done

d=$(newcase existing "${conf}")
echo "kept-name" > "${d}/etc/device-name"
expect "an existing valid device-name is kept" "${d}" "kept-name"

d=$(newcase existing-invalid "${conf}")
echo "Not Valid" > "${d}/etc/device-name"
expect "an invalid existing device-name is replaced by the install name" "${d}" "lab-pi"

d=$(newcase unreadable "${conf}")
chmod 000 "${d}/config/wendy.conf"
if [ "$(id -u)" -ne 0 ]; then
    expect "an unreadable wendy.conf falls back" "${d}" "brave-dolphin"
fi
chmod 644 "${d}/config/wendy.conf"

# The agent still consumes wendy.conf, and nothing but the name may leak.
d=$(newcase untouched "${conf}")
before=$(sha256sum "${d}/config/wendy.conf")
out=$(DEVICE_NAME_FILE="${d}/etc/device-name" ADJECTIVES_FILE="${WORK}/adjectives.txt" \
    NOUNS_FILE="${WORK}/nouns.txt" WENDY_CONF="${d}/config/wendy.conf" bash "${SCRIPT}" 2>&1)
if [ "$(sha256sum "${d}/config/wendy.conf")" = "${before}" ]; then
    ok "wendy.conf is left for the agent"
else
    bad "wendy.conf was modified"
fi
case "${out}" in
    *hunter2-secret*) bad "the Wi-Fi password reached the log" ;;
    *) ok "the Wi-Fi password never reaches the log" ;;
esac

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
