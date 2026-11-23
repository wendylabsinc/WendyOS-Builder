#!/usr/bin/env bash
# Tests for the name gadget-setup.sh gives the board on USB — plain bash, no
# framework, same shape as update-mdns-uuid.test.sh.
#
# Covers:
#   (a) the name is taken in the agent's order (DeviceName in hostname.go): the
#       hostname from 'wendy device rename', else the device-name, else the
#       serial suffix. Before the fix only device-name was read, so a renamed
#       board kept its old USB name on every boot.
#   (b) a name file with junk in it is skipped instead of being written into
#       the USB product string, and a missing helper library costs the name
#       but does not stop the script.
#   (c) the product string still carries "wendy", which is how the CLI knows
#       the USB network port on macOS, and leaves room for the name: macOS
#       keeps 31 characters as the port name, and "WendyOS Device " left 16 of
#       them, so hackathon-device-5 and -6 shared one port name.
#
# gadget-setup.sh needs configfs and a USB controller to run, so this sources
# it for its functions (it returns before touching either) and calls them
# under the script's own shell options. Fully isolated: every path points into
# a temp tree.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_DIR}/gadget-setup.sh"
IDENTITY_LIB_FILE="${SCRIPT_DIR}/../../wendyos-identity/files/wendyos-identity-lib.sh"

if [ ! -f "${IDENTITY_LIB_FILE}" ]; then
    echo "FAIL - identity helpers not found at ${IDENTITY_LIB_FILE}" >&2
    exit 1
fi

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

SERIAL="1a2b3c4d"   # the serial suffix the script falls back to
LIB="${IDENTITY_LIB_FILE}"
OUT=""              # name=, product= and log lines from the last run

# build_fixture DEVICE_NAME EXPLICIT_HOSTNAME — "" means an absent file.
build_fixture() {
    rm -rf "${WORK:?}"/*
    mkdir -p "${WORK}/wendyos" "${WORK}/wendy-agent"
    [ -n "$1" ] && printf '%s\n' "$1" > "${WORK}/wendyos/device-name"
    [ -n "$2" ] && printf '%s\n' "$2" > "${WORK}/wendy-agent/hostname"
    return 0
}

# Resolve the name against the fixture the way the script's main flow does,
# with its shell options, so a step that would abort gadget setup shows up as
# a missing name.
run_only() {
    OUT=$(DEVICE_NAME_FILE="${WORK}/wendyos/device-name" \
          EXPLICIT_HOSTNAME_FILE="${WORK}/wendy-agent/hostname" \
          IDENTITY_LIB="${LIB}" \
              bash -c '
                  set -euo pipefail
                  source "$1"
                  log_info()    { echo "info: $1"; }
                  log_warning() { echo "warning: $1"; }
                  log_error()   { echo "error: $1"; }
                  resolve_device_name "$2"
                  echo "name=${DEVICE_FRIENDLY_NAME}"
                  echo "product=$(usb_product_string "${DEVICE_FRIENDLY_NAME}")"
              ' gadget-setup "${SCRIPT}" "${SERIAL}" 2>&1) || true
}

# run_resolver DEVICE_NAME EXPLICIT_HOSTNAME
run_resolver() { build_fixture "$@"; run_only; }

# product_for NAME -> the product string for a board of that name
product_for() {
    bash -c 'source "$1"; usb_product_string "$2"' gadget-setup "${SCRIPT}" "$1"
}

# What macOS keeps of a product string as the name of the network port.
port_name() { printf '%s' "${1:0:31}"; }

field() { sed -n "s/^$1=//p" <<< "${OUT}"; }

assert_field() {
    local key="$1" want="$2" label="$3" got
    got=$(field "${key}")
    if [[ "${got}" == "${want}" ]]; then
        ok "${label}: ${key}=${want}"
    else
        bad "${label}: ${key}=${got} (want ${want})"
    fi
}

assert_out() {
    local needle="$1" label="$2"
    if [[ "${OUT}" == *"${needle}"* ]]; then
        ok "${label}"
    else
        bad "${label}: output did not contain '${needle}' (got: ${OUT})"
    fi
}

# --- (a) the agent's order: rename, device-name, serial ----------------------
run_resolver "brave-dolphin" "kitchen-pi"
assert_field name    "kitchen-pi"         "rename wins over device-name"
assert_field product "WendyOS kitchen-pi" "rename wins over device-name"
assert_out "from ${WORK}/wendy-agent/hostname" "rename wins: source logged"

run_resolver "brave-dolphin" ""
assert_field name "brave-dolphin" "no rename"
assert_out "from ${WORK}/wendyos/device-name" "no rename: source logged"

# A fresh A/B slot or a wiped /etc/wendyos: the rename alone still names it.
run_resolver "" "kitchen-pi"
assert_field name "kitchen-pi" "rename without a device-name"

run_resolver "" ""
assert_field name "${SERIAL}" "no name file falls back to the serial"
assert_out "using serial" "no name file: fallback logged"

# --- (b) junk never reaches the product string -------------------------------
# Uppercase is lowercased before validation, so it is accepted, not rejected.
run_resolver "brave-dolphin" "Kitchen-Pi"
assert_field name "kitchen-pi" "uppercase rename is lowercased"

LABEL64="a$(printf 'b%.0s' $(seq 63))"
for junk in "-leading-hyphen" "trailing-hyphen-" "1starts-with-digit" "has_underscore" \
            "has.dot" "has space" "a&b" "a|b" "a<b" "${LABEL64}"; do
    run_resolver "brave-dolphin" "${junk}"
    assert_field name "brave-dolphin" "invalid rename '${junk:0:20}' falls back to device-name"
done
assert_out "is not a valid hostname label" "invalid rename warns"

# A 63-character label is the longest the agent accepts and must be accepted.
LABEL63="a$(printf 'b%.0s' $(seq 62))"
run_resolver "brave-dolphin" "${LABEL63}"
assert_field name "${LABEL63}" "63-char rename accepted"

# An empty rename file is absent-equivalent.
run_resolver "brave-dolphin" " "
assert_field name "brave-dolphin" "blank rename falls back"

# A 0-byte file is the shape a failed /data copy leaves behind.
build_fixture "brave-dolphin" ""
: > "${WORK}/wendy-agent/hostname"
run_only
assert_field name "brave-dolphin" "0-byte rename falls back"

# A corrupt multi-line file is truncated, never joined into a plausible name.
build_fixture "brave-dolphin" ""
printf 'kitchen-pi\nold-name\n' > "${WORK}/wendy-agent/hostname"
run_only
assert_field name "kitchen-pi" "multi-line rename uses the first line only"

build_fixture "brave-dolphin" ""
printf 'kitchen-pi\r\n' > "${WORK}/wendy-agent/hostname"
run_only
assert_field name "kitchen-pi" "CRLF rename is tolerated"

# The device-name gets the same checks. The old code deleted every space in it,
# which turned two words into one name, and passed anything else through,
# however long.
for junk in "brave dolphin" "a&b" "$(printf 'x%.0s' $(seq 200))"; do
    run_resolver "${junk}" ""
    assert_field name "${SERIAL}" "invalid device-name '${junk:0:20}' falls back to the serial"
done

run_resolver "a&b" "also_junk"
assert_field name "${SERIAL}" "two invalid name files fall back to the serial"

# Without the helpers nothing can be validated. The gadget must still come up,
# so the script carries on under the serial.
build_fixture "brave-dolphin" "kitchen-pi"
LIB="${WORK}/no-such-lib.sh"
run_only
LIB="${IDENTITY_LIB_FILE}"
assert_field name "${SERIAL}" "missing helpers fall back to the serial"
assert_out "Cannot source identity helpers" "missing helpers warn"

# --- (c) the product string --------------------------------------------------
# Every released CLI knows the board's USB port on macOS by "wendy" in its name.
product=$(product_for "brave-dolphin")
if [[ "$(printf '%s' "${product}" | tr '[:upper:]' '[:lower:]')" == *wendy* ]]; then
    ok "product string contains 'wendy': ${product}"
else
    bad "product string '${product}' does not contain 'wendy'"
fi

# The names from the report: they differ in the 18th character.
port5=$(port_name "$(product_for "hackathon-device-5")")
port6=$(port_name "$(product_for "hackathon-device-6")")
if [[ "${port5}" != "${port6}" ]]; then
    ok "hackathon-device-5 and -6 get different macOS port names"
else
    bad "hackathon-device-5 and -6 share the macOS port name '${port5}'"
fi

# A 23-character name is the longest that macOS shows whole.
NAME23="a$(printf 'b%.0s' $(seq 22))"
product=$(product_for "${NAME23}")
if [[ "$(port_name "${product}")" == "${product}" && "${product}" == *"${NAME23}" ]]; then
    ok "a 23-character name fits the macOS port name"
else
    bad "a 23-character name is cut in the macOS port name: '$(port_name "${product}")'"
fi

# The board never shortens a name itself: a longer one is passed whole and it
# is the host that cuts it. 126 characters is the longest USB string configfs
# accepts, and a failed write there would stop the gadget.
product=$(product_for "${LABEL63}")
if [[ "${product}" == *"${LABEL63}" && "${#product}" -le 126 ]]; then
    ok "the longest name is passed whole and fits a USB string (${#product} chars)"
else
    bad "the longest name gives an unusable product string: '${product}'"
fi

echo
echo "passed: ${pass}, failed: ${fail}"
[ "${fail}" -eq 0 ]
