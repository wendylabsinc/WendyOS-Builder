#!/bin/sh
#
# Applies the board's factory Wi-Fi or Bluetooth address, stored in the eMMC
# boot area (partitions wlanaddr and bdaddr). The kernel boots with the slot's
# devicetree, not the one U-Boot writes them into, so the Wi-Fi driver otherwise
# picks a random MAC every boot, and Bluetooth stays unconfigured with the
# chip's default address.
#
#   wendyos-radio-addr.sh wlan <ifname>   from udev, before the link is managed
#   wendyos-radio-addr.sh bt              once the controller is registered
set -eu

log() { echo "wendyos-radio-addr: $*" > /dev/kmsg 2>/dev/null || true; }

# The stored address, or nothing when the partition is missing, blank or not a
# unicast address.
factory_addr() {
    part=/dev/disk/by-partlabel/$1
    [ -e "$part" ] || return 0
    # shellcheck disable=SC2046  # split into the six bytes
    set -- $(od -An -tx1 -N6 "$part")
    [ $# -eq 6 ] || return 0
    case "$1$2$3$4$5$6" in 000000000000|ffffffffffff) return 0 ;; esac
    [ $((0x$1 & 1)) -eq 0 ] || return 0
    echo "$1:$2:$3:$4:$5:$6"
}

# btmgmt exits 0 on failure too, so success is read back from the controller.
bt_has() { btmgmt --index 0 info 2>/dev/null | grep -q "addr $1 "; }

case "${1:-}" in
wlan)
    addr=$(factory_addr wlanaddr)
    [ -n "$addr" ] || { log "no valid factory Wi-Fi address"; exit 0; }
    ip link set dev "$2" address "$addr"
    log "$2: factory address $addr"
    ;;
bt)
    addr=$(factory_addr bdaddr | tr a-f A-F)
    [ -n "$addr" ] || { log "no valid factory Bluetooth address"; exit 0; }
    i=0
    until btmgmt --index 0 config 2>/dev/null | grep -q "supported options"; do
        i=$((i + 1))
        [ $i -lt 30 ] || { log "hci0 did not come up"; exit 1; }
        sleep 1
    done
    bt_has "$addr" && exit 0
    if btmgmt --index 0 config | grep -q "missing options: public-address"; then
        # Setting the address configures the controller; bluetoothd then
        # powers it up.
        btmgmt --index 0 public-addr "$addr" >/dev/null
    else
        # A configured controller only takes a new address while powered off.
        btmgmt --index 0 power off >/dev/null
        btmgmt --index 0 public-addr "$addr" >/dev/null
        btmgmt --index 0 power on >/dev/null
    fi
    i=0
    until bt_has "$addr"; do
        i=$((i + 1))
        [ $i -lt 10 ] || { log "hci0 did not take $addr"; exit 1; }
        sleep 1
    done
    log "hci0: factory address $addr"
    ;;
*)
    echo "usage: $0 wlan <ifname> | bt" >&2
    exit 2
    ;;
esac
