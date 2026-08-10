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
#   (c) a corrupt/invalid explicit hostname falls back to device-name rather
#       than burning junk into the advertisement.
#   (d) records the agent owns at runtime (tls, port) are never clobbered.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${SCRIPT_DIR}/update-mdns-uuid.sh"

# update-mdns-uuid.sh edits in place with `sed -i -E`, which is GNU syntax; BSD
# sed (macOS) reads the -E pattern as a filename and silently leaves the service
# file untouched, so every assertion here would fail for the wrong reason. Use
# gsed when it is installed, and refuse to run — loudly, not as a silent pass —
# when no GNU sed is available. On device and in CI (Linux) this is a no-op.
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

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# Build a fresh fixture tree and run the publisher against it.
# run_publisher DEVICE_NAME EXPLICIT_HOSTNAME  ("" for an absent file)
run_publisher() {
    local device_name="$1" explicit="$2"
    rm -rf "${WORK:?}"/*
    mkdir -p "${WORK}/wendyos" "${WORK}/wendy-agent" "${WORK}/avahi"

    echo "3f2b1a7c-0d4e-4b8a-9c1d-2e5f6a7b8c9d" > "${WORK}/wendyos/device-uuid"
    [ -n "${device_name}" ] && echo "${device_name}" > "${WORK}/wendyos/device-name"
    [ -n "${explicit}" ] && echo "${explicit}" > "${WORK}/wendy-agent/hostname"

    # Mirrors the shipped template plus the runtime records the agent adds once
    # the device is provisioned (see UpdateAvahiForProvisioning).
    cat > "${WORK}/avahi/wendyos-mdns.service" <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service protocol="any">
    <type>_wendyos._udp</type>
    <port>50052</port>
    <txt-record>id=WENDY_DEVICE_ID</txt-record>
    <txt-record>name=WENDY_DEVICE_NAME</txt-record>
    <txt-record>displayname=WENDY_DISPLAY_NAME</txt-record>
    <txt-record>tls=true</txt-record>
  </service>
</service-group>
EOF

    UUID_FILE="${WORK}/wendyos/device-uuid" \
    DEVICE_NAME_FILE="${WORK}/wendyos/device-name" \
    EXPLICIT_HOSTNAME_FILE="${WORK}/wendy-agent/hostname" \
    SERVICE_FILE="${WORK}/avahi/wendyos-mdns.service" \
        bash "${SCRIPT}" >/dev/null 2>&1
}

# txt KEY -> the value currently advertised for that TXT record
txt() {
    sed -n -E "s|.*<txt-record>$1=([^<]*)</txt-record>.*|\1|p" \
        "${WORK}/avahi/wendyos-mdns.service"
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

# --- (a) an explicit rename wins and is advertised verbatim ------------------
# The literal hostname is used as-is: no "wendyos-" prefix is derived from it.
run_publisher "brave-dolphin" "kitchen-pi"
assert_txt name        "kitchen-pi"  "explicit rename wins"
assert_txt displayname "Kitchen Pi"  "explicit rename wins"

# --- (b) no rename in effect: device-name still drives the advertisement -----
run_publisher "brave-dolphin" ""
assert_txt name        "brave-dolphin" "no rename"
assert_txt displayname "Brave Dolphin" "no rename"

# --- (c) an invalid explicit hostname falls back to device-name --------------
# Uppercase is lowercased before validation, so it is accepted, not rejected.
run_publisher "brave-dolphin" "Kitchen-Pi"
assert_txt name        "kitchen-pi" "uppercase explicit is lowercased"
assert_txt displayname "Kitchen Pi" "uppercase explicit is lowercased"

for junk in "-leading-hyphen" "trailing-hyphen-" "1starts-with-digit" "has_underscore" "has.dot"; do
    run_publisher "brave-dolphin" "${junk}"
    assert_txt name "brave-dolphin" "invalid explicit '${junk}' falls back"
done

# An empty explicit file is absent-equivalent, not a reason to advertise "".
run_publisher "brave-dolphin" " "
assert_txt name "brave-dolphin" "blank explicit falls back"

# --- (d) runtime records the agent owns survive ------------------------------
run_publisher "brave-dolphin" "kitchen-pi"
assert_txt tls "true" "agent-owned records preserved"
if grep -q "<port>50052</port>" "${WORK}/avahi/wendyos-mdns.service"; then
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
