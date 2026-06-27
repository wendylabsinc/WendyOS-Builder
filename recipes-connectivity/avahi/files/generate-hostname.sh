#!/bin/bash
#
# Hostname Generation Script
# Generates a unique hostname based on device UUID (fallback to serial/MAC)
#

set -Eeuo pipefail

UUID_FILE="/etc/wendyos/device-uuid"
DEVICE_NAME_FILE="/etc/wendyos/device-name"
# Explicit, literal hostname set at runtime via the agent's SetHostname RPC
# (wendy device rename). When present and valid it is used verbatim, with no
# "wendyos-" prefix, taking precedence over the device-name and UUID sources.
EXPLICIT_HOSTNAME_FILE="/etc/wendy-agent/hostname"
PREFIX="wendyos"
STATE_DIR="/etc/wendyos"
STATE_HOSTNAME_FILE="${STATE_DIR}/hostname"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    logger -t wendyos-hostname "$*" || true
}

# Validate UUID (accepts with/without dashes, case-insensitive)
is_valid_uuid() {
    local v="${1,,}"
    [[ "$v" =~ ^[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}$ ]]
}

# Validate a literal hostname as a single DNS label: starts with a lowercase
# letter, then lowercase letters/digits/hyphens, not ending in a hyphen, 1-63
# characters. Mirrors validHostname in the wendy-agent (services/hostname.go).
is_valid_hostname() {
    local v="$1"
    [[ "$v" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# Primary source: device UUID
get_device_uuid() {
    local uuid=""
    if [ -r "$UUID_FILE" ]; then
        uuid="$(tr -d '[:space:]' < "$UUID_FILE" 2>/dev/null || true)"
    fi
    echo "$uuid"
}

# Fallback legacy ID (serial/MAC/machine-id) – used only if UUID is missing/invalid
get_legacy_id() {
    local device_id=""
    # Raspberry Pi serial
    if [ -f /proc/cpuinfo ]; then
        device_id=$(grep -m1 '^Serial' /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | tr -d ' ' || true)
    fi
    # machine-id (partial)
    if [ -z "${device_id}" ] && [ -f /etc/machine-id ]; then
        device_id=$(head -c 16 /etc/machine-id || true)
    fi
    # first MAC
    if [ -z "${device_id}" ]; then
        device_id=$(ip link show | awk '/ether/ {gsub(":","",$2); print $2; exit}')
    fi
    # random fallback
    if [ -z "${device_id}" ]; then
        device_id=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 16)
    fi
    echo "$device_id"
}

# Generate hostname from an explicit literal hostname (preferred), the
# human-readable device name, or a UUID/legacy ID (fallback)
generate_hostname() {
    local explicit device_name uuid short_id legacy

    # An explicit hostname set via 'wendy device rename' wins and is used
    # verbatim, with no "wendyos-" prefix.
    if [ -f "$EXPLICIT_HOSTNAME_FILE" ]; then
        explicit=$(cat "$EXPLICIT_HOSTNAME_FILE" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [ -n "$explicit" ] && is_valid_hostname "$explicit"; then
            echo "$explicit"
            return
        fi
    fi

    # Try to use the human-readable device name first
    if [ -f "$DEVICE_NAME_FILE" ]; then
        device_name=$(cat "$DEVICE_NAME_FILE" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [ -n "$device_name" ]; then
            echo "${PREFIX}-${device_name}"
            return
        fi
    fi

    # Fallback to UUID-based hostname
    uuid="$(get_device_uuid)"
    if [ -n "$uuid" ] && is_valid_uuid "$uuid"; then
        uuid="${uuid//-/}"
        uuid="${uuid,,}"
        short_id="${uuid: -8}"
    else
        legacy="$(get_legacy_id)"
        legacy="${legacy//-/}"
        legacy="${legacy,,}"
        short_id="${legacy: -8}"
    fi

    echo "${PREFIX}-${short_id}"
}

# Set hostname
set_hostname() {
    local new_hostname="$1"
    local current_hostname
    current_hostname=$(hostname || echo "")

    if [ "${current_hostname}" = "${new_hostname}" ]; then
        log "Hostname already set to ${new_hostname}"
        return 0
    fi

    log "Setting hostname to ${new_hostname}"

    # Write directly to /etc/hostname instead of using hostnamectl
    # Rationale: hostnamectl uses atomic rename() which fails with EBUSY if
    # /etc/hostname were bind-mounted. Direct write works in all cases.
    echo "${new_hostname}" > /etc/hostname
    hostname "${new_hostname}"

    # Update /etc/hosts (idempotent)
    if [ -f /etc/hosts ]; then
        grep -q "${new_hostname}" /etc/hosts 2>/dev/null || {
            sed -i '/\(wendyos-\|wendyos-\)/d' /etc/hosts 2>/dev/null || true
            echo "127.0.1.1 ${new_hostname} ${new_hostname}.local" >> /etc/hosts
        }
    else
        echo "127.0.1.1 ${new_hostname} ${new_hostname}.local" > /etc/hosts
    fi

    log "Hostname set successfully to ${new_hostname}"
}

main() {
    log "Starting WendyOS hostname generation"

    # Allow opt-out
    if [ -f /etc/wendyos-hostname-override ]; then
        log "Hostname override found, skipping automatic generation"
        exit 0
    fi

    mkdir -p "${STATE_DIR}"

    local new
    new="$(generate_hostname)"
    set_hostname "${new}"

    echo "${new}" > "${STATE_HOSTNAME_FILE}"

    # Note: avahi-daemon starts AFTER this service (Before=avahi-daemon.service)
    # so it will pick up the hostname from gethostname() when it starts.

    log "WendyOS hostname generation completed: ${new}"
}

main "$@"
