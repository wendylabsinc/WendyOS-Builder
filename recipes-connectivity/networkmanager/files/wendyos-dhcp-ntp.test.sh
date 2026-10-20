#!/usr/bin/env bash
# Tests for wendyos-dhcp-ntp.sh. Sysfs, the drop-in directory and systemctl
# point into a temp tree, so this never touches the host.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wendyos-dhcp-ntp.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
SYSFS="${WORK}/sys"
DROPINS="${WORK}/timesyncd.conf.d"
RESTARTS="${WORK}/restarts"

# link NAME ARPHRD_TYPE [DEVTYPE]
link() {
    mkdir -p "${SYSFS}/$1"
    echo "$2" > "${SYSFS}/$1/type"
    { echo "INTERFACE=$1"; [ -n "${3:-}" ] && echo "DEVTYPE=$3"; } > "${SYSFS}/$1/uevent"
}

reset() {
    rm -rf "${WORK:?}"/*
    : > "${RESTARTS}"
    printf '#!/bin/sh\necho "$*" >> "%s"\n' "${RESTARTS}" > "${WORK}/systemctl"
    chmod +x "${WORK}/systemctl"
    link eth0 1; link eth1 1; link veth1a2b 1
    link wlan0 1 wlan; link usb0 1 gadget; link lo 772
}

# dispatch IFACE ACTION [DHCP4_NTP_SERVERS [DHCP6_DHCP6_NTP_SERVERS]]
dispatch() {
    local -a envs=(PATH="${PATH}" SYSFS_NET="${SYSFS}" TIMESYNCD_DROPIN_DIR="${DROPINS}"
                   SYSTEMCTL="${WORK}/systemctl")
    [ $# -ge 3 ] && envs+=(DHCP4_NTP_SERVERS="$3")
    [ $# -ge 4 ] && envs+=(DHCP6_DHCP6_NTP_SERVERS="$4")
    env -i "${envs[@]}" sh "${SCRIPT}" "$1" "$2"
}

dropin() { echo "${DROPINS}/50-wendyos-dhcp-$1.conf"; }

# expect_ntp IFACE SERVERS LABEL — SERVERS "" means no drop-in for IFACE
expect_ntp() {
    if [ -z "$2" ]; then
        if [ ! -e "$(dropin "$1")" ]; then ok "$3"; else bad "$3: unexpected $(dropin "$1")"; fi
    elif printf '[Time]\nNTP=%s\n' "$2" | cmp -s - "$(dropin "$1")"; then
        ok "$3"
    else
        bad "$3: got '$(cat "$(dropin "$1")" 2>/dev/null)', want NTP=$2"
    fi
}

expect_restarts() {
    local got
    got=$(grep -c try-restart "${RESTARTS}")
    if [ "${got}" = "$1" ]; then ok "$2: $1 restart(s)"; else bad "$2: ${got} restarts, want $1"; fi
}

reset
dispatch eth0 up "192.0.2.1 192.0.2.2"
expect_ntp eth0 "192.0.2.1 192.0.2.2" "eth_up_writes_servers"
expect_restarts 1 "eth_up_writes_servers"
if [ "$(cat "${RESTARTS}")" = "$(printf 'reset-failed systemd-timesyncd.service\n--no-block try-restart systemd-timesyncd.service')" ]; then
    ok "restart_resets_start_limit_first"
else
    bad "restart_resets_start_limit_first: $(cat "${RESTARTS}")"
fi

dispatch eth0 dhcp4-change "192.0.2.1 192.0.2.2"
expect_restarts 1 "renewal_same_servers_no_restart"

dispatch eth0 dhcp4-change "192.0.2.3"
expect_ntp eth0 "192.0.2.3" "server_change_rewrites"
expect_restarts 2 "server_change_rewrites"

dispatch eth0 reapply "192.0.2.3"
expect_restarts 2 "reapply_same_servers_no_restart"

reset
dispatch eth0 dhcp6-change "192.0.2.1" "2001:db8::1 192.0.2.1"
expect_ntp eth0 "192.0.2.1 2001:db8::1" "v4_v6_merged_deduped"

reset
dispatch eth0 dhcp6-change "" "ntp1.example.net 2001:db8::1"
expect_ntp eth0 "ntp1.example.net 2001:db8::1" "server_names_kept"

reset
for i in wlan0 usb0 lo veth1a2b; do
    dispatch "$i" up "192.0.2.1"
    expect_ntp "$i" "" "non_ethernet_ignored: $i"
done
expect_restarts 0 "non_ethernet_ignored"

reset
dispatch eth0 up "192.0.2.1 evil;x PollIntervalMinSec=1 *"
expect_ntp eth0 "192.0.2.1" "junk_tokens_dropped"

# A glob must stay literal, or it would expand to file names in the cwd.
reset
mkdir "${WORK}/cwd" && touch "${WORK}/cwd/ntp.example"
(cd "${WORK}/cwd" && dispatch eth0 up "*")
expect_ntp eth0 "" "glob_not_expanded"

reset
dispatch eth0 up
expect_ntp eth0 "" "lease_without_ntp_writes_nothing"
expect_restarts 0 "lease_without_ntp_writes_nothing"
dispatch eth0 up "192.0.2.1"
dispatch eth0 dhcp4-change
expect_ntp eth0 "" "lease_without_ntp_removes_file"
expect_restarts 2 "lease_without_ntp_removes_file"

reset
dispatch eth0 up "192.0.2.1"
dispatch eth0 down
expect_ntp eth0 "" "down_removes_file"
expect_restarts 2 "down_removes_file"

reset
dispatch eth1 up "192.0.2.1"
rm -rf "${SYSFS}/eth1"
dispatch eth1 down
expect_ntp eth1 "" "down_vanished_iface_removes_file"
expect_restarts 2 "down_vanished_iface_removes_file"

reset
dispatch eth0 up "192.0.2.1"
dispatch eth1 up "198.51.100.1"
dispatch eth1 down
expect_ntp eth0 "192.0.2.1" "two_ports_independent"
expect_ntp eth1 "" "two_ports_independent: eth1 removed"

reset
dispatch eth0 up "192.0.2.1"
for action in connectivity-change dns-change hostname; do
    dispatch eth0 "${action}"
done
expect_ntp eth0 "192.0.2.1" "other_actions_ignored"
expect_restarts 1 "other_actions_ignored"

echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
