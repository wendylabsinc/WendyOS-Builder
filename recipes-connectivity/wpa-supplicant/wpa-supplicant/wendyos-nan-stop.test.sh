#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
HELPER=$SCRIPT_DIR/wendyos-nan
TEST_DIR=$(mktemp -d)
socket_pid=
cleanup() {
    [ -z "$socket_pid" ] || kill "$socket_pid" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT HUP INT TERM

export WENDYOS_NAN_RUNTIME_DIR="$TEST_DIR/runtime"
export WENDYOS_NAN_GLOBAL_CTRL="$TEST_DIR/global"
export WENDYOS_NAN_IFACE_CTRL="$TEST_DIR"
export WENDYOS_NAN_WPA_CLI="$TEST_DIR/wpa_cli"
export WENDYOS_NAN_SYSTEMCTL="$TEST_DIR/systemctl"
export WENDYOS_NAN_TEST_STATE="$TEST_DIR/ifaces"
export WENDYOS_NAN_TEST_SYSTEMCTL_LOG="$TEST_DIR/systemctl.log"

cat >"$WENDYOS_NAN_WPA_CLI" <<'EOF'
#!/bin/sh
case " $* " in
*" status ")
    [ "${WENDYOS_NAN_TEST_STATUS_FAIL:-0}" = 0 ] || exit 1
    cat "$WENDYOS_NAN_TEST_STATE" ;;
*" nan_status ") echo "nan_started=${WENDYOS_NAN_TEST_NAN_STARTED:-1}" ;;
*" GET_CAPABILITY nan ") echo 'USD NAN' ;;
*" nan_stop ") echo OK ;;
*" nan_start ")
    if [ "${WENDYOS_NAN_TEST_START_FAIL:-0}" = 1 ]; then echo FAIL; else echo OK; fi ;;
*" interface_remove nan0 ")
    awk '/^ifname=/ { removed = ($0 == "ifname=nan0") } !removed' \
        "$WENDYOS_NAN_TEST_STATE" >"$WENDYOS_NAN_TEST_STATE.tmp"
    mv "$WENDYOS_NAN_TEST_STATE.tmp" "$WENDYOS_NAN_TEST_STATE"
    echo OK ;;
*" interface_add nan0 "*)
    printf 'ifname=nan0\nphyname=phy0\nnan_mgmt=1\nnan_data=0\n' >>"$WENDYOS_NAN_TEST_STATE"
    echo OK ;;
*) echo "unexpected wpa_cli command: $*" >&2; exit 1 ;;
esac
EOF
cat >"$WENDYOS_NAN_SYSTEMCTL" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$WENDYOS_NAN_TEST_SYSTEMCTL_LOG"
if [ "$*" = 'restart wpa_supplicant.service' ]; then
    printf 'ifname=p2p-dev-wlan0\nphyname=phy0\nnan_mgmt=0\nnan_data=0\n' >>"$WENDYOS_NAN_TEST_STATE"
fi
EOF
chmod +x "$WENDYOS_NAN_WPA_CLI" "$WENDYOS_NAN_SYSTEMCTL"

assert_absent() {
    pattern=$1
    file=$2
    if grep -q "$pattern" "$file"; then
        echo "Unexpected $pattern in $file" >&2
        exit 1
    fi
}

# The helper checks for a live Unix control socket before accessing supplicant.
python3 - "$WENDYOS_NAN_GLOBAL_CTRL" <<'PY' &
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.listen(1)
time.sleep(30)
PY
socket_pid=$!
attempts=0
while [ ! -S "$WENDYOS_NAN_GLOBAL_CTRL" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 50 ] || { echo 'test control socket missing' >&2; exit 1; }
    sleep 0.1
done

mkdir -p "$WENDYOS_NAN_RUNTIME_DIR"
printf 'p2p-dev-wlan0\n' >"$WENDYOS_NAN_RUNTIME_DIR/p2p-interfaces"
printf 'ifname=wlan0\nphyname=phy0\nnan_mgmt=0\nnan_data=0\nifname=nan0\nphyname=phy0\nnan_mgmt=1\nnan_data=0\n' >"$WENDYOS_NAN_TEST_STATE"
: >"$WENDYOS_NAN_TEST_SYSTEMCTL_LOG"

"$HELPER" stop >"$TEST_DIR/stop.out" 2>"$TEST_DIR/stop.err"
grep -Fxq ifname=wlan0 "$WENDYOS_NAN_TEST_STATE"
assert_absent '^ifname=nan0$' "$WENDYOS_NAN_TEST_STATE"
test -s "$WENDYOS_NAN_RUNTIME_DIR/p2p-interfaces"
test ! -s "$WENDYOS_NAN_TEST_SYSTEMCTL_LOG"
grep -q 'restoration deferred' "$TEST_DIR/stop.err"

# Repeated stop and the next start retain ownership of the missing P2P device.
"$HELPER" stop >"$TEST_DIR/repeated-stop.out" 2>"$TEST_DIR/repeated-stop.err"
"$HELPER" start >"$TEST_DIR/start.out"
grep -Fxq ifname=nan0 "$WENDYOS_NAN_TEST_STATE"
test -s "$WENDYOS_NAN_RUNTIME_DIR/p2p-interfaces"
assert_absent '^restart ' "$WENDYOS_NAN_TEST_SYSTEMCTL_LOG"

# Explicit restoration must fail closed while NAN owns the radio.
if "$HELPER" restore-p2p >"$TEST_DIR/active-restore.out" 2>"$TEST_DIR/active-restore.err"; then
    echo 'restore-p2p accepted active NAN' >&2
    exit 1
fi
grep -q 'Remove nan0' "$TEST_DIR/active-restore.err"
assert_absent '^restart ' "$WENDYOS_NAN_TEST_SYSTEMCTL_LOG"

"$HELPER" stop >"$TEST_DIR/second-stop.out" 2>"$TEST_DIR/second-stop.err"

# A failed NAN_START must leave station Wi-Fi and the deferred marker intact.
export WENDYOS_NAN_TEST_NAN_STARTED=0
export WENDYOS_NAN_TEST_START_FAIL=1
if "$HELPER" start >"$TEST_DIR/failed-start.out" 2>"$TEST_DIR/failed-start.err"; then
    echo 'failed NAN_START was accepted' >&2
    exit 1
fi
unset WENDYOS_NAN_TEST_NAN_STARTED WENDYOS_NAN_TEST_START_FAIL
grep -Fxq ifname=wlan0 "$WENDYOS_NAN_TEST_STATE"
assert_absent '^ifname=nan0$' "$WENDYOS_NAN_TEST_STATE"
test -s "$WENDYOS_NAN_RUNTIME_DIR/p2p-interfaces"
assert_absent '^restart ' "$WENDYOS_NAN_TEST_SYSTEMCTL_LOG"

# A broken global STATUS must never be interpreted as permission to restart.
export WENDYOS_NAN_TEST_STATUS_FAIL=1
if "$HELPER" restore-p2p >"$TEST_DIR/bad-status.out" 2>"$TEST_DIR/bad-status.err"; then
    echo 'restore-p2p accepted a broken global STATUS' >&2
    exit 1
fi
unset WENDYOS_NAN_TEST_STATUS_FAIL
assert_absent '^restart ' "$WENDYOS_NAN_TEST_SYSTEMCTL_LOG"
test -s "$WENDYOS_NAN_RUNTIME_DIR/p2p-interfaces"

"$HELPER" restore-p2p >"$TEST_DIR/restore.out"
grep -Fxq 'restart wpa_supplicant.service' "$WENDYOS_NAN_TEST_SYSTEMCTL_LOG"
grep -Fxq ifname=p2p-dev-wlan0 "$WENDYOS_NAN_TEST_STATE"
test ! -e "$WENDYOS_NAN_RUNTIME_DIR/p2p-interfaces"

# A second restore is a no-op; no extra disruption occurs.
"$HELPER" restore-p2p >"$TEST_DIR/repeated-restore.out"
test "$(grep -c '^restart ' "$WENDYOS_NAN_TEST_SYSTEMCTL_LOG")" -eq 1

# If another owner already restored P2P, clear only the stale marker.
printf 'p2p-dev-wlan0\n' >"$WENDYOS_NAN_RUNTIME_DIR/p2p-interfaces"
"$HELPER" restore-p2p >"$TEST_DIR/already-restored.out"
test ! -e "$WENDYOS_NAN_RUNTIME_DIR/p2p-interfaces"
test "$(grep -c '^restart ' "$WENDYOS_NAN_TEST_SYSTEMCTL_LOG")" -eq 1

"$HELPER" stop >"$TEST_DIR/no-marker-stop.out"
test "$(grep -c '^restart ' "$WENDYOS_NAN_TEST_SYSTEMCTL_LOG")" -eq 1

echo 'wendyos-nan stop/restore tests passed'
