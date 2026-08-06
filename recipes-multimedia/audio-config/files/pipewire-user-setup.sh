#!/bin/bash
# pipewire-user-setup.sh
# Enables PipeWire and WirePlumber user services for the wendy user
# Also ensures runtime directory exists for containers to access audio

set -e

USER="wendy"
USER_HOME="/home/wendy"

# Fail if user doesn't exist (don't fallback to UID 1000)
if ! USER_UID=$(id -u "$USER" 2>/dev/null); then
    echo "ERROR: User '$USER' does not exist"
    exit 1
fi

RUNTIME_DIR="/run/user/$USER_UID"

if [ ! -d "$USER_HOME" ]; then
    echo "User home directory $USER_HOME does not exist yet"
    exit 0
fi

echo "Setting up audio for user: $USER (UID: $USER_UID)"

# Enable user lingering (keeps user services running, creates /run/user/UID)
if ! loginctl enable-linger "$USER"; then
    echo "ERROR: Failed to enable lingering for $USER"
    exit 1
fi

# Wait for systemd to create runtime directory (with timeout)
wait_for_runtime_dir() {
    local timeout=10
    local count=0

    while [ ! -d "$RUNTIME_DIR" ]; do
        if [ $count -ge $timeout ]; then
            echo "ERROR: Runtime directory $RUNTIME_DIR not created after ${timeout}s"
            return 1
        fi
        sleep 0.5
        count=$((count + 1))
    done

    echo "Runtime directory ready: $RUNTIME_DIR"
    return 0
}

if ! wait_for_runtime_dir; then
    # Fallback: create manually if systemd didn't
    echo "Creating runtime directory manually: $RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
    chown "$USER:$USER" "$RUNTIME_DIR"
    chmod 700 "$RUNTIME_DIR"
fi

# Wait for a socket file to exist (with timeout)
wait_for_socket() {
    local socket_path="$1"
    local timeout=10
    local count=0

    while [ ! -S "$socket_path" ]; do
        if [ $count -ge $timeout ]; then
            echo "ERROR: Socket $socket_path not ready after ${timeout}s"
            return 1
        fi
        sleep 0.5
        count=$((count + 1))
    done

    echo "Socket ready: $socket_path"
    return 0
}

# Wait for the user manager's own D-Bus socket before running any
# `systemctl --user` command against it. `loginctl enable-linger` starts
# user@$USER_UID.service asynchronously: the runtime directory above appears
# almost immediately, but the user manager's control socket ($RUNTIME_DIR/bus)
# takes a bit longer to bind. Without this wait, the `su` block below races
# it and fails with "Failed to connect to user scope bus via local
# transport: No such file or directory".
if ! wait_for_socket "$RUNTIME_DIR/bus"; then
    echo "ERROR: user@$USER_UID.service's D-Bus socket never appeared"
    exit 1
fi

# Enable and start user services as the wendy user
su - "$USER" -c "
    set -e
    export XDG_RUNTIME_DIR=$RUNTIME_DIR
    export DBUS_SESSION_BUS_ADDRESS=unix:path=\$XDG_RUNTIME_DIR/bus

    echo 'Starting D-Bus user session...'
    systemctl --user start dbus.service

    echo 'Starting PipeWire sockets...'
    systemctl --user start pipewire.socket pipewire-pulse.socket

    echo 'Starting WirePlumber session manager...'
    systemctl --user start wireplumber.service

    echo 'Verifying services are running...'
    systemctl --user is-active --quiet dbus.service || {
        echo 'ERROR: D-Bus service not running'
        exit 1
    }

    systemctl --user is-active --quiet pipewire.socket || {
        echo 'ERROR: PipeWire socket not running'
        exit 1
    }

    systemctl --user is-active --quiet pipewire-pulse.socket || {
        echo 'ERROR: PipeWire-Pulse socket not running'
        exit 1
    }

    systemctl --user is-active --quiet wireplumber.service || {
        echo 'ERROR: WirePlumber service not running'
        exit 1
    }

    echo 'Audio services started successfully'
"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to start user audio services"
    exit 1
fi

# Verify critical sockets exist
echo "Verifying audio sockets exist..."
wait_for_socket "$RUNTIME_DIR/bus" || {
    echo "ERROR: D-Bus socket missing"
    exit 1
}

wait_for_socket "$RUNTIME_DIR/pipewire-0" || {
    echo "ERROR: PipeWire socket missing"
    exit 1
}

wait_for_socket "$RUNTIME_DIR/pulse/native" || {
    echo "ERROR: PulseAudio compatibility socket missing"
    exit 1
}

# Make runtime directory accessible to audio group (not world-readable)
# Containers running as audio group can access sockets
if getent group audio >/dev/null 2>&1; then
    chgrp audio "$RUNTIME_DIR"
    chmod 750 "$RUNTIME_DIR"
    echo "Runtime directory permissions: 750 (user=rwx, audio=rx, other=none)"
else
    # Fallback if audio group doesn't exist
    chmod 755 "$RUNTIME_DIR"
    echo "WARNING: audio group not found, using 755 permissions"
fi

echo "=== Audio Setup Complete ==="
echo "User: $USER (UID: $USER_UID)"
echo "Runtime dir: $RUNTIME_DIR"
echo "D-Bus socket: $RUNTIME_DIR/bus"
echo "PipeWire socket: $RUNTIME_DIR/pipewire-0"
echo "Pulse socket: $RUNTIME_DIR/pulse/native"
echo ""
echo "Container usage:"
echo "  podman run --device=nvidia.com/gpu=all --group-add audio \\"
echo "    -e PULSE_SERVER=unix:$RUNTIME_DIR/pulse/native \\"
echo "    -e XDG_RUNTIME_DIR=$RUNTIME_DIR \\"
echo "    your-image:latest"

exit 0
