#!/bin/sh
# Setup 4GB swap file on /data partition

SWAPFILE="/data/swapfile"
SWAPSIZE_MB=4096

# Verify /data is mounted
if ! mountpoint -q /data; then
    echo "ERROR: /data is not mounted, cannot create swap file"
    exit 1
fi

# Check if swap file already exists and is active
if [ -f "$SWAPFILE" ] && swapon --show | grep -q "$SWAPFILE"; then
    echo "Swap file $SWAPFILE already active"
    exit 0
fi

# Create swap file if it doesn't exist
if [ ! -f "$SWAPFILE" ]; then
    echo "Creating ${SWAPSIZE_MB}MB swap file at $SWAPFILE..."

    # Check available space on /data. Swap is an optimization, not a boot
    # requirement: if /data is too small (e.g. a not-yet-grown or undersized
    # partition), skip and log rather than failing the unit and leaving a red
    # entry in `systemctl --failed`. The data-swapfile.swap unit is
    # ConditionPathExists-gated, so it is skipped too when no file is created.
    AVAILABLE_MB=$(df -BM /data | tail -1 | awk '{print $4}' | sed 's/M//')
    if [ "$AVAILABLE_MB" -lt "$((SWAPSIZE_MB + 1024))" ]; then
        echo "WARNING: not enough space on /data for swap (need ${SWAPSIZE_MB}MB + 1GB buffer, have ${AVAILABLE_MB}MB); skipping swap setup"
        exit 0
    fi

    # Allocate the swap file (use fallocate for speed, fallback to dd)
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${SWAPSIZE_MB}M" "$SWAPFILE" || {
            echo "fallocate failed, falling back to dd..."
            dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAPSIZE_MB status=progress || {
                echo "ERROR: Failed to create swap file"
                exit 1
            }
        }
    else
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAPSIZE_MB status=progress || {
            echo "ERROR: Failed to create swap file"
            exit 1
        }
    fi

    # Set proper permissions (readable/writable by root only)
    chmod 600 "$SWAPFILE"

    # Setup as swap
    mkswap "$SWAPFILE" || {
        echo "ERROR: Failed to format swap file"
        rm -f "$SWAPFILE"
        exit 1
    }

    echo "Swap file created successfully"
fi

# Enable swap
if ! swapon --show | grep -q "$SWAPFILE"; then
    echo "Enabling swap file..."
    swapon "$SWAPFILE" || {
        echo "ERROR: Failed to enable swap"
        exit 1
    }
    echo "Swap enabled successfully"
fi

exit 0
