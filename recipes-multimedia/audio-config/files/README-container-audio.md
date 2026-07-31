# Container Audio and Camera Access Guide

## Overview
WendyOS runs a single system-wide PipeWire graph. `pipewire` and `wireplumber`
both run as the `pipewire` user under systemd, so audio, Bluetooth and cameras
are available to system services and containers without a login session.

## How It Works

| Resource | Path |
|---|---|
| PipeWire socket | `/run/pipewire/pipewire-0` |
| PulseAudio compatibility socket | `/run/pipewire/pulse/native` |
| ALSA devices | `/dev/snd/*` |
| Bluetooth control | system D-Bus (`/run/dbus/system_bus_socket`) |

The sockets are owned by `pipewire:pipewire` with mode `0660`, so a container
needs either root (the default) or membership of the `pipewire` group.

## Running Containers with Audio

```bash
podman run \
    --device /dev/snd \
    -v /run/pipewire:/run/pipewire \
    -e PIPEWIRE_RUNTIME_DIR=/run/pipewire \
    -e PULSE_SERVER=unix:/run/pipewire/pulse/native \
    your-image:latest
```

## Using a Camera from a Container

PipeWire owns the camera, so several consumers can read one device at the same
time — an app and a remote viewer, or two apps.

```bash
# App that speaks PipeWire natively (GStreamer, libcamera, ...)
podman run \
    -v /run/pipewire:/run/pipewire \
    -e PIPEWIRE_RUNTIME_DIR=/run/pipewire \
    your-image:latest

# App that only knows /dev/videoN — redirect it through PipeWire
pw-v4l2 your-camera-app
```

## Troubleshooting

```bash
# Is the session manager up? (Without it the graph is empty.)
systemctl status pipewire wireplumber

# What did WirePlumber publish?
sudo -u pipewire PIPEWIRE_RUNTIME_DIR=/run/pipewire wpctl status

# Camera nodes only — look for media.class = Video/Source
sudo -u pipewire PIPEWIRE_RUNTIME_DIR=/run/pipewire pw-dump | grep -A2 Video/Source
```

`Permission denied` on the socket means the process is neither root nor in the
`pipewire` group.

## Pairing Bluetooth Speakers

```bash
bluetoothctl
> power on
> scan on
> pair XX:XX:XX:XX:XX:XX
> connect XX:XX:XX:XX:XX:XX
> trust XX:XX:XX:XX:XX:XX
> exit
```

Once paired, PipeWire routes audio to the Bluetooth speaker automatically.
