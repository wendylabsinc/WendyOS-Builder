#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
HELPER=$SCRIPT_DIR/wendyos-nan
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM

LOG=$TEST_DIR/wpa-cli.log
MOCK=$TEST_DIR/wpa_cli

cat >"$MOCK" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$WENDYOS_NAN_TEST_LOG"
case " $* " in
*" -g "*" status "*)
    printf 'ifname=nan0\nphyname=phy0\nnan_mgmt=1\nnan_data=0\nifname=ndi0\nphyname=phy0\nnan_mgmt=0\nnan_data=1\n'
    ;;
*)
    printf 'OK\n'
    ;;
esac
EOF
chmod +x "$MOCK"

export WENDYOS_NAN_RUNTIME_DIR="$TEST_DIR/runtime"
export WENDYOS_NAN_TEST_LOG="$LOG"
export WENDYOS_NAN_WPA_CLI="$MOCK"
export WENDYOS_NAN_GLOBAL_CTRL=/ctrl/global
export WENDYOS_NAN_IFACE_CTRL=/ctrl

assert_last() {
    want=$1
    got=$(tail -n 1 "$LOG")
    if [ "$got" != "$want" ]; then
        printf 'got:  %s\nwant: %s\n' "$got" "$want" >&2
        exit 1
    fi
}

"$HELPER" publish-sync service_name=wendy.test ttl=60 >/dev/null
assert_last '-p /ctrl -i nan0 nan_publish service_name=wendy.test ttl=60 sync=1'

"$HELPER" subscribe-sync service_name=wendy.test ttl=60 >/dev/null
assert_last '-p /ctrl -i nan0 nan_subscribe service_name=wendy.test ttl=60 sync=1'

"$HELPER" schedule-default >/dev/null
assert_last '-p /ctrl -i nan0 nan_sched_config_map map_id=1 2437:0e000000'

"$HELPER" schedule map_id=7 2462:0e000000 >/dev/null
assert_last '-p /ctrl -i nan0 nan_sched_config_map map_id=7 2462:0e000000'

# The mock status contains ndi0, so removal exercises the global control path.
"$HELPER" ndi-remove >/dev/null
assert_last '-g /ctrl/global interface_remove ndi0'

# A non-default name is absent and therefore exercises NDI creation.
"$HELPER" ndi-create ndp-test >/dev/null
assert_last '-g /ctrl/global interface_add ndp-test  nl80211 /ctrl   create nan_data  nan0'

"$HELPER" ndp-request handle=3 ndi=ndi0 peer_nmi=00:11:22:33:44:55 >/dev/null
assert_last '-p /ctrl -i nan0 nan_ndp_request handle=3 ndi=ndi0 peer_nmi=00:11:22:33:44:55'

"$HELPER" ndp-respond accept ndp_id=4 ndi=ndi0 >/dev/null
assert_last '-p /ctrl -i nan0 nan_ndp_response accept ndp_id=4 ndi=ndi0'

"$HELPER" ndp-terminate ndp_id=4 >/dev/null
assert_last '-p /ctrl -i nan0 nan_ndp_terminate ndp_id=4'

printf 'wendyos-nan tests passed\n'
