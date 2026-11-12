#!/bin/bash
#
# WendyOS Device Name Generation Script
# Generates a unique human-readable device name on first boot
# Format: adjective-noun (e.g., brave-dolphin)
#

set -Eeuo pipefail

DEVICE_NAME_FILE="${DEVICE_NAME_FILE:-/etc/wendyos/device-name}"
DEVICE_NAME_DIR=$(dirname "$DEVICE_NAME_FILE")
ADJECTIVES_FILE="${ADJECTIVES_FILE:-/usr/share/wendyos/adjectives.txt}"
NOUNS_FILE="${NOUNS_FILE:-/usr/share/wendyos/nouns.txt}"
# Written by the CLI at flash time; the agent applies and deletes it later in
# boot, too late for gadget-setup, which bakes the name into the USB descriptor.
WENDY_CONF="${WENDY_CONF:-/config/wendy.conf}"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    logger -t wendyos-device-name "$*" || true
}

# A device name: letter-led, 3-55 chars, no trailing hyphen, so "wendyos-<name>"
# stays a valid DNS label. Mirrors validDeviceName in the agent (apply.go).
is_valid_device_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z][a-z0-9-]{1,53}[a-z0-9]$ ]]
}

# [device] name from wendy.conf, parsed like the agent's parseINI (apply.go):
# trimmed lines, '#'/';' comments, last duplicate wins. Prints nothing when the
# file is absent, unreadable or has no valid name; never fails.
flash_time_name() {
    local name
    [ -r "$WENDY_CONF" ] || return 0
    name=$(awk '
        { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        $0 == "" || /^[#;]/ { next }
        /^\[.*\]$/ { section = substr($0, 2, length($0) - 2); next }
        section == "device" && index($0, "=") > 1 {
            key = substr($0, 1, index($0, "=") - 1); val = substr($0, index($0, "=") + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
            if (key == "name") name = val
        }
        END { print name }
    ' "$WENDY_CONF" 2>/dev/null) || return 0
    [ -n "$name" ] || return 0
    if is_valid_device_name "$name"; then
        echo "$name"
    else
        log "WARNING: Ignoring invalid device name in $WENDY_CONF: ${name:0:64}" >&2
    fi
}

# Generate random device name from word lists
generate_random_name() {
    local adjective noun

    # Check if word list files exist
    if [ ! -f "$ADJECTIVES_FILE" ] || [ ! -f "$NOUNS_FILE" ]; then
        log "ERROR: Word list files not found"
        log "Expected: $ADJECTIVES_FILE and $NOUNS_FILE"
        # Fallback to UUID-based name
        local uuid_file="/etc/wendyos/device-uuid"
        if [ -f "$uuid_file" ]; then
            local uuid=$(cat "$uuid_file" | tr -d '[:space:]-' | tr '[:upper:]' '[:lower:]')
            echo "device-${uuid: -8}"
        else
            echo "device-$(tr -dc 'a-f0-9' < /dev/urandom | head -c 8)"
        fi
        return
    fi

    # Get random adjective and noun
    adjective=$(shuf -n 1 "$ADJECTIVES_FILE" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    noun=$(shuf -n 1 "$NOUNS_FILE" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    echo "${adjective}-${noun}"
}

main() {
    log "Starting WendyOS device name generation"

    # Create directory if it doesn't exist
    if [ ! -d "$DEVICE_NAME_DIR" ]; then
        mkdir -p "$DEVICE_NAME_DIR"
        chmod 755 "$DEVICE_NAME_DIR"
    fi

    # Check if device name already exists
    if [ -f "$DEVICE_NAME_FILE" ]; then
        existing_name=$(cat "$DEVICE_NAME_FILE" | tr -d '[:space:]')

        # Validate existing name
        if is_valid_device_name "$existing_name"; then
            log "Device name already exists and is valid: $existing_name"
            exit 0
        else
            log "WARNING: Existing device name is invalid: $existing_name"
            log "Generating new device name..."
        fi
    fi

    # Prefer the name given at flash time, else generate one
    new_name=$(flash_time_name)
    if [ -n "$new_name" ]; then
        log "Using device name from $WENDY_CONF: $new_name"
    else
        new_name=$(generate_random_name)
    fi

    # Validate generated name
    if ! is_valid_device_name "$new_name"; then
        log "ERROR: Generated name is invalid: $new_name"
        log "Using fallback name"
        new_name="device-$(tr -dc 'a-f0-9' < /dev/urandom | head -c 8)"
    fi

    # Write device name to file
    echo "$new_name" > "$DEVICE_NAME_FILE"
    chmod 644 "$DEVICE_NAME_FILE"

    log "Generated new device name: $new_name"

    # Also write to kernel log for debugging
    logger -t wendyos-device-name "Generated device name: $new_name"
}

main "$@"
