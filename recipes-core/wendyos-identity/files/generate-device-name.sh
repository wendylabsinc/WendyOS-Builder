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
# Written by `wendy install`; the agent applies and removes it later.
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

# Print the [device] name from wendy.conf, parsed like the agent's parseINI
# (trimmed lines, # and ; comments, last value wins). Only this key is read:
# the file also holds Wi-Fi passwords.
name_from_config() {
    [ -r "$WENDY_CONF" ] || return 0
    awk '
        { sub(/\r$/, ""); line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
        line == "" || line ~ /^[#;]/ { next }
        line ~ /^\[.*\]$/ { section = substr(line, 2, length(line) - 2); next }
        section == "device" {
            i = index(line, "=")
            if (i > 1) {
                key = substr(line, 1, i - 1); gsub(/^[ \t]+|[ \t]+$/, "", key)
                if (key == "name") { val = substr(line, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", val); name = val }
            }
        }
        END { print name }
    ' "$WENDY_CONF" 2>/dev/null || true
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
            local uuid
            uuid=$(tr -d '[:space:]-' < "$uuid_file" | tr '[:upper:]' '[:lower:]')
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
        existing_name=$(tr -d '[:space:]' < "$DEVICE_NAME_FILE")

        # Validate existing name
        if is_valid_device_name "$existing_name"; then
            log "Device name already exists and is valid: $existing_name"
            exit 0
        else
            log "WARNING: Existing device name is invalid: $existing_name"
            log "Generating new device name..."
        fi
    fi

    # The name chosen at install time, so the board is never seen under a
    # random name before the agent applies wendy.conf.
    new_name=""
    config_name=$(name_from_config)
    if [ -n "$config_name" ]; then
        if is_valid_device_name "$config_name"; then
            new_name="$config_name"
            log "Using the device name chosen at install: $new_name"
        else
            log "WARNING: Ignoring invalid device name in $WENDY_CONF: $config_name"
        fi
    fi

    if [ -z "$new_name" ]; then
        new_name=$(generate_random_name)

        # Validate generated name
        if ! is_valid_device_name "$new_name"; then
            log "ERROR: Generated name is invalid: $new_name"
            log "Using fallback name"
            new_name="device-$(tr -dc 'a-f0-9' < /dev/urandom | head -c 8)"
        fi
    fi

    # Write device name to file
    echo "$new_name" > "$DEVICE_NAME_FILE"
    chmod 644 "$DEVICE_NAME_FILE"

    log "Set device name: $new_name"

    # Also write to kernel log for debugging
    logger -t wendyos-device-name "Set device name: $new_name"
}

main "$@"
