#!/bin/bash
#
# WendyOS Device Name Generation Script
# Generates a unique human-readable device name on first boot
# Format: adjective-noun (e.g., brave-dolphin)
#

set -Eeuo pipefail

DEVICE_NAME_FILE="/etc/wendyos/device-name"
DEVICE_NAME_DIR=$(dirname "$DEVICE_NAME_FILE")
ADJECTIVES_FILE="/usr/share/wendyos/adjectives.txt"
NOUNS_FILE="/usr/share/wendyos/nouns.txt"

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

    # Generate new device name
    new_name=$(generate_random_name)

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
