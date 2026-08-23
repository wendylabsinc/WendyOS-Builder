#!/bin/sh
#
# Lower the uplink MTU when the path is smaller than the link.
#
# Carrier LTE/CGNAT uplinks commonly have a path MTU below 1500 and drop the
# ICMP frag-needed that classic PMTU discovery depends on, so full-size frames
# vanish in silence. net.ipv4.tcp_mtu_probing (see
# /etc/sysctl.d/99-wendyos-pmtu.conf) rescues host TCP, but it cannot help
# containers (the sysctl is per network namespace), UDP/QUIC, or the inbound
# direction -- the MSS we advertise comes from the link MTU. Lowering the link
# MTU fixes all three at once.
#
# WHAT DECIDES: any established host TCP socket. tcp_mtu_probing has already
# made the kernel discover the real segment size, and ss reports it. A socket
# clamped to around tcp_base_mss while the interface still reports pmtu 1500
# means this path is constricted.
#
# WHY ANY SOCKET IS SAFE: a small mss can also be what the PEER asked for --
# measured on a healthy 1500-byte link, sockets sat at 1400, 1388, 1326, 1288,
# 1240 and 555 against advmss 1448 -- so "below advmss" is useless as a rule.
# The band below is not "small", though: advertised values derive from real
# MTUs (1500->1460, 1492->1452, 1420->1380, 1400->1360, 1280->1240) and nothing
# legitimately advertises between 1240 and the loss-collapse rungs at 600 and
# below. Our own clamp lands at 1188-1200, inside that empty gap. So the band
# identifies our kernel's verdict wherever it appears, which means this needs
# neither the agent to be running nor the device to be enrolled -- an OTA
# download or a containerd image pull (both host-netns TCP) reveals it just as
# well.
#
# WHY 1280 AND NOT A MEASURED VALUE: the socket proves the path is constricted
# but not by how much. An idle control connection never meets the conditions
# for probing back upward (cwnd >= 11 plus queued data), so its mss stays
# parked at tcp_base_mss. 1280 is the smallest MTU any compliant path must
# carry, so it needs no measurement and cannot be too large. Sites that want
# the throughput back can measure and set a per-profile MTU by hand, which this
# script then leaves alone.
#
# NOTHING IS PERSISTED, AND THAT IS THE SELF-CORRECTING CHOICE. The MTU is
# applied with `ip link set`, which changes only the running link, and the
# bookkeeping lives in /run, so every boot re-decides from 1500.
#
# The obvious objection is "why not remember it and skip the detection delay?"
# Because clamping destroys the sensor. Once the link is at 1280 every socket's
# mss is <= 1228, and the kernel refuses to send a DF packet larger than the
# local MTU (EMSGSIZE, locally, before it ever reaches the wire) -- so there is
# no way to ask "would 1500 work now?" without unclamping first. A carrier-side
# improvement would therefore be invisible forever. Re-deciding at boot is
# periodic re-validation at the cheapest possible moment: the link is fresh and
# nothing depends on it yet. A degradation needs no re-validation at all, since
# 1280 is below anything a compliant path can be.
# NetworkManager does not restore the MTU by itself (with nothing configured
# _commit_mtu() keeps whatever the link currently has), so the restore below is
# required, not decorative.

set -u

STATE_DIR="/run/uplink-mtu-tuning"
STATE="${STATE_DIR}/applied"

# The MTU to fall back to. 1280 = the IPv6 minimum link MTU.
CONSTRICTED_MTU=1280

# The signature is a NARROW BAND around tcp_base_mss, not "small". When PLPMTUD
# detects a black hole it clamps the socket to exactly mss(base_mss): 1200, or
# 1188 once the 12-byte timestamp option is subtracted. Both bounds earn their
# keep:
#
#   upper -- a small mss can also be what the PEER asked for. Our endpoint
#   advertises 1400 (measured), plain hosts advertise 1460, CDN clamps sit at
#   1360-1400, and the smallest realistic case is an overlay-fronted endpoint at
#   1240 (WireGuard/Tailscale 1280 MTU). 1210 stays clear of all of them, and
#   unlike a round number it is derived from our own tcp_base_mss.
#
#   lower -- on a FALSE positive (ordinary loss, not a size problem) nothing
#   ever fits, so the kernel keeps halving: 1200, 600, 300, down to
#   tcp_mtu_probe_floor. A socket below the first rung is evidence of loss, not
#   of a constricted path, and clamping the link would be the wrong answer.
MSS_TRIGGER_HIGH=1210
MSS_TRIGGER_LOW=1150

# Only ever act on a link still sitting at the Ethernet default. Anything else
# means somebody already decided: a DHCP server that advertised option 26 (which
# NetworkManager applies as MTU_SOURCE_IP_CONFIG), a provisioned per-profile MTU,
# or a previous run of this script. Deferring to all three for free is the point
# -- the network's own answer always beats ours.
DEFAULT_MTU=1500

# The socket's pmtu must still look full-size for its mss to mean anything.
LINK_FLOOR=1400

# Runs as a systemd unit, so stdout and stderr already land in the journal under
# SyslogIdentifier=uplink-mtu-tuning. logger(1) is deliberately not used: it
# comes from util-linux-logger, which is not part of a release image.
log() {
    echo "$1"
}

warn() {
    echo "$1" >&2
}

# The uplink is the interface of the first default route. The gateway comes
# along as a cheap fingerprint of "which network is this", so that moving the
# unit to another network is noticed.
read_uplink() {
    ip route show default 2>/dev/null | awk '
        $1 == "default" {
            dev = ""
            gw = "-"
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") dev = $(i + 1)
                if ($i == "via") gw = $(i + 1)
            }
            if (dev != "") {
                print dev, gw
                exit
            }
        }'
}

link_mtu() {
    cat "/sys/class/net/$1/mtu" 2>/dev/null || echo 0
}

# Which per-connection MTU property to inspect: 802-3-ethernet.mtu for wired,
# 802-11-wireless.mtu for WiFi. A carrier uplink can be either -- an LTE router
# or phone hotspot is reached over wlan0. Used only for the operator-override
# check below; failing to resolve a type makes that check treat the profile as
# configured, so anything exotic (WWAN, tunnels) is left alone rather than
# guessed at.
mtu_property() {
    case "$(nmcli -g GENERAL.TYPE device show "$1" 2>/dev/null)" in
        ethernet)
            echo "802-3-ethernet.mtu"
            ;;
        wifi)
            echo "802-11-wireless.mtu"
            ;;
        *)
            return 1
            ;;
    esac
}

# Applied with `ip link set`, NOT `nmcli device modify`. Verified on an AGX Orin
# 2026-08-23: nmcli reports "Connection successfully reapplied" and returns 0,
# NM's audit log agrees, and the link MTU does not change. The reason is that
# _commit_mtu() is reached from activation, the L3-config notify callback, port
# attach and the parent-device handlers -- never from the reapply path, which
# only resets mtu_source so that a LATER commit will accept the value. So the
# MTU would sit in the applied connection until the next activation.
#
# `ip link set` is also the better fit: it is runtime-only, which is exactly the
# lifetime we want, and it needs nothing from NetworkManager. Nothing reverts it
# either -- with no MTU configured anywhere, a later _commit_mtu() falls through
# to mtu_desired = mtu_plat and keeps whatever the link currently has.
#
# The readback is not paranoia. Reporting success on the strength of an exit
# code is what hid this bug for a whole test run: the log said "MTU set to 1280"
# while the link stayed at 1500.
set_mtu() {
    ip link set dev "$1" mtu "$2" >/dev/null 2>&1 || return 1
    [ "$(link_mtu "$1")" = "$2" ]
}

# An explicit per-profile MTU is somebody's deliberate decision -- a
# provisioning step, or a site with a known path. Never override it.
profile_mtu_is_set() {
    _profile=$(nmcli -g GENERAL.CONNECTION device show "$1" 2>/dev/null)
    [ -n "${_profile}" ] || return 1
    _prop=$(mtu_property "$1") || return 0
    _mtu=$(nmcli -g "${_prop}" connection show "${_profile}" 2>/dev/null)
    case "${_mtu}" in
        "" | 0 | auto)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Print "mss pmtu peer process" for the first clamped socket, nothing otherwise.
# ss prints each socket on one line and its counters on the next, indented, so
# the peer and process are remembered from the socket line and tested on the
# line that follows. -p is only for the log message; the decision does not use
# it.
clamped_socket() {
    ss -tinp state established 2>/dev/null | awk \
        -v hi="${MSS_TRIGGER_HIGH}" -v lo="${MSS_TRIGGER_LOW}" \
        -v floor="${LINK_FLOOR}" '
        /^[ \t]/ {
            mss = 0
            pmtu = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^mss:/) {
                    split($i, a, ":")
                    mss = a[2] + 0
                }
                if ($i ~ /^pmtu:/) {
                    split($i, a, ":")
                    pmtu = a[2] + 0
                }
            }
            if (mss >= lo && mss <= hi && pmtu >= floor) {
                print mss, pmtu, peer, proc
                exit
            }
            next
        }
        {
            peer = $4
            proc = $5
        }'
}

uplink=$(read_uplink)
[ -n "${uplink}" ] || exit 0

dev=${uplink% *}
gw=${uplink#* }
fingerprint="${dev}|${gw}"

# Already decided? Restore and re-decide if the network changed, otherwise
# leave it alone.
if [ -f "${STATE}" ]
then
    IFS='|' read -r s_dev s_gw s_mtu < "${STATE}" || true
    if [ "${s_dev}|${s_gw}" = "${fingerprint}" ]
    then
        exit 0
    fi
    if set_mtu "${s_dev}" "${s_mtu}"
    then
        log "network changed (${s_dev}|${s_gw} -> ${fingerprint}); restored MTU ${s_mtu} on ${s_dev}"
    else
        warn "network changed but restoring MTU ${s_mtu} on ${s_dev} failed"
    fi
    rm -f "${STATE}"
fi

mtu=$(link_mtu "${dev}")
[ "${mtu}" -eq "${DEFAULT_MTU}" ] || exit 0

if profile_mtu_is_set "${dev}"
then
    exit 0
fi

hit=$(clamped_socket)
[ -n "${hit}" ] || exit 0

mkdir -p "${STATE_DIR}"
printf '%s|%s|%s\n' "${dev}" "${gw}" "${mtu}" > "${STATE}"

if set_mtu "${dev}" "${CONSTRICTED_MTU}"
then
    log "${dev}: clamped socket (mss pmtu peer proc = ${hit}) with link MTU ${mtu}; path is constricted, MTU set to ${CONSTRICTED_MTU}"
else
    warn "${dev}: constricted path detected (mss pmtu peer proc = ${hit}) but setting MTU ${CONSTRICTED_MTU} failed"
    rm -f "${STATE}"
fi
