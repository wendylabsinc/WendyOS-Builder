#!/usr/bin/env bash
# Tests for update-mdns-uuid.sh — plain bash, no framework, same shape as
# wendyos-agent-updater.test.sh.
#
# Covers the reboot half of "wendy device rename does not stick":
#   (a) an explicit hostname from 'wendy device rename' wins over the generated
#       device-name and is advertised verbatim. Before the fix this publisher
#       re-derived name/displayname from device-name on EVERY boot, so the
#       rename survived as the hostname but the mDNS advertisement — which is
#       what 'wendy device list' shows — reverted to the old name.
#   (b) with no rename in effect, device-name still drives the advertisement.
#   (c) an already-renamed device whose device-name later changes keeps the
#       explicit name, and re-running changes nothing.
#   (d) a fresh A/B slot, where the rootfs service file is back to placeholders
#       and device-name has not been generated yet, still honours the rename.
#   (e) a corrupt/invalid explicit hostname falls back to device-name rather
#       than burning junk into the advertisement.
#   (f) records the agent owns at runtime (tls, port) are never clobbered.
#
# Fully isolated: every path, both generators and the avahi reload are pointed
# at the temp tree, so running this never touches /etc or a live avahi-daemon.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_DIR}/update-mdns-uuid.sh"
IDENTITY_LIB_FILE="${SCRIPT_DIR}/wendyos-identity-lib.sh"
# Built from the shipped template, not a hand-copied literal, so a change to the
# real service file is caught here instead of drifting silently.
TEMPLATE="${SCRIPT_DIR}/../../../recipes-connectivity/avahi/files/wendyos-mdns.service"

# update-mdns-uuid.sh edits in place with `sed -i -E`, which is GNU syntax; BSD
# sed (macOS) reads the -E pattern as a filename and silently leaves the service
# file untouched, so every assertion here would fail for the wrong reason. Use
# gsed when it is installed, and refuse to run — loudly, not as a silent pass —
# when no GNU sed is available. On device and in CI (Linux) this is a no-op.
SHIM=""
if ! sed --version >/dev/null 2>&1; then
    if command -v gsed >/dev/null 2>&1; then
        SHIM=$(mktemp -d)
        ln -s "$(command -v gsed)" "${SHIM}/sed"
        PATH="${SHIM}:${PATH}"
        export PATH
    else
        echo "SKIP - update-mdns-uuid.test.sh requires GNU sed (brew install gnu-sed), or run it on Linux" >&2
        exit 99
    fi
fi

if [ ! -f "${TEMPLATE}" ]; then
    echo "FAIL - shipped template not found at ${TEMPLATE}" >&2
    exit 1
fi

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}" ${SHIM:+"${SHIM}"}' EXIT

SERVICE=""   # set by build_fixture
OUT=""       # publisher stdout+stderr from the last run

# build_fixture DEVICE_NAME EXPLICIT_HOSTNAME [PRIOR_NAME]
# "" means an absent file. PRIOR_NAME simulates a previous boot having already
# published a real name, which is what the service file looks like on every boot
# after the first (an A/B slot switch is what resets it to the placeholders).
build_fixture() {
    local device_name="$1" explicit="$2" prior="${3:-}"
    rm -rf "${WORK:?}"/*
    mkdir -p "${WORK}/wendyos" "${WORK}/wendy-agent" "${WORK}/avahi" "${WORK}/bin"
    SERVICE="${WORK}/avahi/wendyos-mdns.service"

    echo "3f2b1a7c-0d4e-4b8a-9c1d-2e5f6a7b8c9d" > "${WORK}/wendyos/device-uuid"
    [ -n "${device_name}" ] && printf '%s\n' "${device_name}" > "${WORK}/wendyos/device-name"
    [ -n "${explicit}" ] && printf '%s\n' "${explicit}" > "${WORK}/wendy-agent/hostname"

    # The shipped template plus the tls record the agent inserts once the device
    # is provisioned (see UpdateAvahiForProvisioning).
    sed 's|</service>|  <txt-record>tls=true</txt-record>\n  </service>|' \
        "${TEMPLATE}" > "${SERVICE}"

    if [ -n "${prior}" ]; then
        sed -i -E "s|(<txt-record>name=)[^<]*|\1${prior}|; \
                   s|(<txt-record>displayname=)[^<]*|\1Prior Name|" "${SERVICE}"
    fi
}

# Stand in for /usr/bin/generate-device-name.sh so the self-heal path can run
# without invoking the real generator or writing to the real /etc.
install_generator_stub() {
    cat > "${WORK}/bin/generate-device-name.sh" <<EOF
#!/bin/bash
echo "${1}" > "${WORK}/wendyos/device-name"
EOF
    chmod +x "${WORK}/bin/generate-device-name.sh"
}

# Run the publisher against the fixture with no host side effects.
run_only() {
    OUT=$(UUID_FILE="${WORK}/wendyos/device-uuid" \
          DEVICE_NAME_FILE="${WORK}/wendyos/device-name" \
          EXPLICIT_HOSTNAME_FILE="${WORK}/wendy-agent/hostname" \
          SERVICE_FILE="${SERVICE}" \
          GENERATE_DEVICE_NAME_SH="${WORK}/bin/generate-device-name.sh" \
          GENERATE_HOSTNAME_SH="${WORK}/bin/generate-hostname.sh" \
          AVAHI_RELOAD_CMD=true \
          IDENTITY_WAIT_SECS=0 \
          IDENTITY_LIB="${IDENTITY_LIB_FILE}" \
              bash "${SCRIPT}" 2>&1)
}

# run_publisher DEVICE_NAME EXPLICIT_HOSTNAME [PRIOR_NAME]
run_publisher() { build_fixture "$@"; run_only; }

# txt KEY -> the value currently advertised for that TXT record
txt() {
    sed -n -E "s|.*<txt-record>$1=([^<]*)</txt-record>.*|\1|p" "${SERVICE}"
}

assert_txt() {
    local key="$1" want="$2" label="$3" got
    got=$(txt "${key}")
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

# --- (a) an explicit rename wins and is advertised verbatim ------------------
# The literal hostname is used as-is: no "wendyos-" prefix is derived from it.
run_publisher "brave-dolphin" "kitchen-pi"
assert_txt name        "kitchen-pi"           "explicit rename wins"
assert_txt displayname "Kitchen Pi"           "explicit rename wins"
assert_out "[from explicit hostname]"         "explicit rename wins: provenance logged"

# --- (b) no rename in effect: device-name still drives the advertisement -----
run_publisher "brave-dolphin" ""
assert_txt name        "brave-dolphin"           "no rename"
assert_txt displayname "Brave Dolphin"           "no rename"
assert_out "[from device name]"                  "no rename: provenance logged"

# --- (c) already renamed, then the device-name changes underneath ------------
# The scenario the fix exists for: a previous boot published a real name, the
# device-name has since been re-applied to something new, and the operator's
# rename must still be the one mDNS advertises.
run_publisher "new-device-name" "kitchen-pi" "old-device-name"
assert_txt name        "kitchen-pi"           "renamed device, device-name changed"
assert_txt displayname "Kitchen Pi"           "renamed device, device-name changed"

# ...and running it again must not churn the file.
BEFORE=$(cat "${SERVICE}")
run_only
if [[ "$(cat "${SERVICE}")" == "${BEFORE}" ]]; then
    ok "re-running the publisher is a no-op"
else
    bad "re-running the publisher changed the service file"
fi

# --- (d) fresh A/B slot after a rename --------------------------------------
# The new slot brings a pristine rootfs service file (placeholders again) while
# /data still carries the rename; device-name has not been generated yet, so
# this also exercises the generator self-heal.
build_fixture "" "kitchen-pi"
install_generator_stub "regenerated-name"
run_only
assert_txt name        "kitchen-pi"  "fresh A/B slot keeps the rename"
assert_txt displayname "Kitchen Pi"  "fresh A/B slot keeps the rename"
assert_out "generating it (self-heal)" "fresh A/B slot: generator self-heal ran"
if [[ "$(cat "${WORK}/wendyos/device-name")" == "regenerated-name" ]]; then
    ok "fresh A/B slot: device-name was regenerated but did not win"
else
    bad "fresh A/B slot: generator stub did not run"
fi

# --- (e) an invalid explicit hostname falls back to device-name --------------
# Uppercase is lowercased before validation, so it is accepted, not rejected.
run_publisher "brave-dolphin" "Kitchen-Pi"
assert_txt name        "kitchen-pi" "uppercase explicit is lowercased"
assert_txt displayname "Kitchen Pi" "uppercase explicit is lowercased"

# Includes the sed/XML metacharacters that would corrupt the service file if
# they reached set_txt unvalidated.
for junk in "-leading-hyphen" "trailing-hyphen-" "1starts-with-digit" "has_underscore" \
            "has.dot" "has space" "a&b" "a|b" "a<b" \
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; do
    run_publisher "brave-dolphin" "${junk}"
    assert_txt name        "brave-dolphin" "invalid explicit '${junk}' falls back"
    assert_txt displayname "Brave Dolphin" "invalid explicit '${junk}' falls back"
done
assert_out "is not a valid hostname label" "invalid explicit warns"

# A device-name carrying the same metacharacters must not reach set_txt either.
run_publisher "a&b" ""
assert_txt name "WENDY_DEVICE_NAME" "invalid device-name leaves placeholder"
assert_out "is not a valid hostname label" "invalid device-name warns"

# A 63-character label is the RFC 1035 maximum and must still be accepted.
LABEL63="a$(printf 'b%.0s' $(seq 62))"
run_publisher "brave-dolphin" "${LABEL63}"
assert_txt name "${LABEL63}" "63-char label accepted"

# An empty explicit file is absent-equivalent, not a reason to advertise "".
run_publisher "brave-dolphin" " "
assert_txt name "brave-dolphin" "blank explicit falls back"

# A 0-byte file is the shape a failed /data copy leaves behind.
build_fixture "brave-dolphin" ""
: > "${WORK}/wendy-agent/hostname"
run_only
assert_txt name "brave-dolphin" "0-byte explicit falls back"

# A corrupt multi-line file must be rejected or truncated, never repaired into a
# valid-looking name by joining the lines.
build_fixture "brave-dolphin" ""
printf 'kitchen-pi\nold-name\n' > "${WORK}/wendy-agent/hostname"
run_only
assert_txt name "kitchen-pi" "multi-line explicit uses the first line only"

# --- displayname must match the agent's avahiDisplayName exactly -------------
# strings.Split on "-" keeps the empty segment, so a--b renders with TWO spaces.
# Collapsing it here makes the agent rewrite the file and restart avahi-daemon.
run_publisher "brave-dolphin" "a--b"
assert_txt displayname "A  B" "consecutive hyphens keep both spaces"

# --- (f) runtime records the agent owns survive ------------------------------
run_publisher "brave-dolphin" "kitchen-pi"
assert_txt tls "true" "agent-owned records preserved"
if grep -q "<port>50051</port>" "${SERVICE}"; then
    ok "agent-owned records preserved: port unchanged"
else
    bad "agent-owned records preserved: port was rewritten"
fi
assert_txt id "3f2b1a7c-0d4e-4b8a-9c1d-2e5f6a7b8c9d" "uuid published"

# --- neither name source present: leave the placeholder for a later run ------
run_publisher "" ""
assert_txt name "WENDY_DEVICE_NAME" "no name source leaves placeholder"

echo
echo "passed: ${pass}, failed: ${fail}"
[ "${fail}" -eq 0 ]
