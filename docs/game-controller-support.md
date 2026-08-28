# Native game-controller support

WendyOS leaves pairing, trust, and reconnect ownership with BlueZ and exposes
controllers to applications through the standard Linux input stack. There is
no Wendy controller daemon, mapping database, or rumble API.

Every shipping kernel recipe includes
`recipes-kernel/linux/wendy-game-controller.inc`. Its shared fragment enables
evdev, joydev, generic/USB/userspace HID, Bluetooth HIDP, xpad, and Microsoft's
HID quirks. The kernel task checks the effective Kconfig result, and build CI
checks each modular result against the finished image manifest.

## On-device smoke test

For Bluetooth, put the controller in pairing mode, find its address with
`wendy device bluetooth`, then pair and trust it:

```sh
wendy device bluetooth connect <address>
```

Deploy a service with `{ "type": "input" }`. Inside that service, verify the
controller appears, inspect its stable identity, and confirm it emits events:

```sh
ls -l /dev/input/by-id
python3 - <<'PY'
from evdev import InputDevice, list_devices

for path in list_devices():
    device = InputDevice(path)
    print(path, device.name, device.uniq, sorted(device.capabilities()))
PY
```

Repeat with the same controller connected over USB. Event numbers are not
stable; applications should select a compatible device by capabilities and,
when pinning is needed, use its evdev `uniq` or `/dev/input/by-id` basename.
