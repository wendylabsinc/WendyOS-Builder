# Container Audio Access Guide

## Overview
WendyOS provides complete audio and Bluetooth speaker support for containers through PipeWire, ALSA, and D-Bus.

## How It Works

Containers get audio access through:
1. **ALSA devices** (`/dev/snd/*`) - Direct hardware access
2. **PipeWire sockets** (`/run/user/1000/pipewire-0`) - Modern audio routing
3. **PulseAudio compatibility** (`/run/user/1000/pulse`) - Legacy app support
4. **D-Bus session** (`/run/user/1000/bus`) - Bluetooth control

## Running Containers with Audio

### Using CDI (Recommended)
```bash
# With podman
podman run --device=nvidia.com/gpu=all \
    -e PULSE_SERVER=unix:/run/user/1000/pulse/native \
    -e XDG_RUNTIME_DIR=/run/user/1000 \
    your-image:latest

# With docker
docker run --runtime=nvidia --device=nvidia.com/gpu=all \
    -e PULSE_SERVER=unix:/run/user/1000/pulse/native \
    -e XDG_RUNTIME_DIR=/run/user/1000 \
    your-image:latest
```

The CDI device annotation (`--device=nvidia.com/gpu=all`) automatically mounts:
- `/dev/snd/*` - ALSA devices
- `/run/user/1000/*` - PipeWire/Pulse/D-Bus sockets
- `/etc/asound.conf` - ALSA config
- `/usr/share/alsa/` - ALSA plugins
- `/usr/lib/pipewire-0.3/` - PipeWire modules

### Manual Volume Mounts (Alternative)
```bash
podman run \
    --device /dev/snd \
    -v /run/user/1000:/run/user/1000:ro \
    -v /etc/asound.conf:/etc/asound.conf:ro \
    -v /usr/share/alsa:/usr/share/alsa:ro \
    -e PULSE_SERVER=unix:/run/user/1000/pulse/native \
    your-image:latest
```

## Testing Audio in Containers

### Test ALSA playback
```bash
podman run --device=nvidia.com/gpu=all \
    -it alpine sh -c "apk add alsa-utils && speaker-test -t wav -c 2"
```

### Test PulseAudio/PipeWire
```bash
podman run --device=nvidia.com/gpu=all \
    -e PULSE_SERVER=unix:/run/user/1000/pulse/native \
    -it ubuntu paplay /usr/share/sounds/alsa/Front_Center.wav
```

### List Bluetooth devices from container
```bash
podman run --device=nvidia.com/gpu=all \
    -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    -it alpine sh -c "apk add bluez && bluetoothctl list"
```

## Pairing Bluetooth Speakers

On the host (or from container with D-Bus access):
```bash
bluetoothctl
> power on
> scan on
> pair XX:XX:XX:XX:XX:XX
> connect XX:XX:XX:XX:XX:XX
> trust XX:XX:XX:XX:XX:XX
> exit
```

Once paired, PipeWire automatically routes audio to the Bluetooth speaker.

## Troubleshooting

### Container can't find audio devices
```bash
# Check if audio devices exist in container
ls -la /dev/snd/

# Check if PipeWire socket is accessible
ls -la /run/user/1000/pipewire-0
```

### No sound output
```bash
# Check PipeWire status on host
systemctl --user status pipewire wireplumber

# Check sinks (output devices)
pactl list sinks short

# Set default sink to Bluetooth speaker
pactl set-default-sink <sink-name>
```

### Permission denied errors
Containers may need to run with `--group-add audio` or as a user in the audio group:
```bash
podman run --device=nvidia.com/gpu=all \
    --group-add audio \
    your-image:latest
```

## Best Practices

1. **Use CDI device annotation** - Automatically handles all mounts
2. **Set PULSE_SERVER env var** - Tells apps where to find PipeWire
3. **Use socket activation** - Don't install PulseAudio in containers
4. **Trust Bluetooth devices** - Prevents re-pairing on reboot
5. **Test with simple tools** - Use `speaker-test` or `paplay` before complex apps
