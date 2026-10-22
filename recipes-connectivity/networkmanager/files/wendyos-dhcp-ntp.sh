#!/bin/sh
# NetworkManager dispatcher: pass an Ethernet lease's NTP servers to
# systemd-timesyncd, which only learns DHCP servers from networkd-managed links.
set -fu

IFACE=$1
ACTION=$2
SYSFS_NET=${SYSFS_NET:-/sys/class/net}
TIMESYNCD_DROPIN_DIR=${TIMESYNCD_DROPIN_DIR:-/run/systemd/timesyncd.conf.d}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
DROPIN=$TIMESYNCD_DROPIN_DIR/50-wendyos-dhcp-$IFACE.conf

# Same links as networkd's 80-wired.network: Type=ether, not veth*.
is_ethernet() {
    case $IFACE in veth*) return 1 ;; esac
    [ "$(cat "$SYSFS_NET/$IFACE/type" 2>/dev/null)" = 1 ] &&
        ! grep -q '^DEVTYPE=' "$SYSFS_NET/$IFACE/uevent"
}

# Name and address tokens only, so a lease cannot add other timesyncd settings.
ntp_servers() {
    servers=
    for s in ${DHCP4_NTP_SERVERS:-} ${DHCP6_DHCP6_NTP_SERVERS:-}; do
        case $s in *[!0-9A-Za-z.:_-]*) continue ;; esac
        case " $servers " in *" $s "*) continue ;; esac
        servers=${servers:+$servers }$s
    done
    echo "$servers"
}

case $ACTION in
    up|dhcp4-change|dhcp6-change|reapply)
        is_ethernet || exit 0
        servers=$(ntp_servers) ;;
    down)
        servers= ;;
    *)
        exit 0 ;;
esac

old=$(cat "$DROPIN" 2>/dev/null)
if [ -n "$servers" ]; then
    new=$(printf '[Time]\nNTP=%s' "$servers")
    [ "$new" = "$old" ] && exit 0
    mkdir -p "$TIMESYNCD_DROPIN_DIR"
    printf '%s\n' "$new" > "$DROPIN.tmp" && mv "$DROPIN.tmp" "$DROPIN"
else
    [ -e "$DROPIN" ] || exit 0
    rm -f "$DROPIN"
fi

# timesyncd reads its servers only at start; reset its start limit so a
# flapping link cannot leave it failed.
"$SYSTEMCTL" reset-failed systemd-timesyncd.service
"$SYSTEMCTL" --no-block try-restart systemd-timesyncd.service
