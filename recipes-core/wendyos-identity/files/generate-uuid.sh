#!/bin/bash
# WendyOS Device UUID Generation Script
# Generates a unique device UUID on first boot

UUID_FILE="/etc/wendyos/device-uuid"
UUID_DIR=$(dirname "$UUID_FILE")

# Keep any UUID that is there. A file with no content (empty or zero-filled) is
# what a power cut during the first write leaves behind; treat it as missing.
if [ -f "$UUID_FILE" ] && [ -n "$(tr -d '\0[:space:]' < "$UUID_FILE")" ]; then
    echo "Device UUID already exists: $(cat "$UUID_FILE")"
    exit 0
fi

# Create directory if it doesn't exist
if [ ! -d "$UUID_DIR" ]; then
    mkdir -p "$UUID_DIR"
    chmod 755 "$UUID_DIR"
fi

# Generate new UUID
NEW_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')

if [ -z "$NEW_UUID" ]; then
    echo "Failed to generate a device UUID" >&2
    exit 1
fi

# Staged, synced and renamed, so a power cut leaves no UUID or a whole one.
UUID_STAGE="${UUID_FILE}.tmp"
if ! { echo "$NEW_UUID" > "$UUID_STAGE" && chmod 644 "$UUID_STAGE" &&
       sync "$UUID_STAGE" && mv -f "$UUID_STAGE" "$UUID_FILE"; }; then
    rm -f "$UUID_STAGE"
    echo "Failed to write $UUID_FILE" >&2
    exit 1
fi
sync "$UUID_DIR" || true

echo "Generated new device UUID: $NEW_UUID"

# Also write to kernel log for debugging
logger -t wendyos-identity "Generated device UUID: $NEW_UUID"