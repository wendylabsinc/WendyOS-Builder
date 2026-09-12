# Native game-controller support

WendyOS exposes controllers to applications through the standard Linux input stack and
leaves pairing, trust and reconnect with BlueZ. There is no Wendy controller daemon,
mapping database or rumble API — an application reads evdev, the same as on any Linux box.

## The contract

`conf/distro/include/game-controller.inc` is the single definition of what a WendyOS
kernel must expose:

- **Built in**, so nothing races a module load: the input and HID cores, `evdev`,
  `hidraw`, USB HID, and the Kconfig gates the drivers below depend on.
- **Built in or modular**: `joydev`, `uhid`, the Bluetooth transport (`bluetooth`,
  `hidp`), and the vendor drivers — `xpad`, Microsoft, PlayStation, Sony, Nintendo,
  Logitech (incl. HID++) and Steam.

Every shipping kernel bbappend requires `recipes-kernel/linux/game-controller.inc` behind
`WENDYOS_GAME_CONTROLLER`, which defaults to `1` and is `0` for QEMU. The kernel task
checks the config Kconfig actually resolved, because a fragment is a request and a vendor
kernel can drop a symbol whose parent it turned off. Where a symbol resolves to a module,
`packagegroup-wendyos-kernel` recommends its package and build CI confirms it landed in
the finished image — `RRECOMMENDS` is forced here, since a symbol built in by the BSP
produces no package at all for an `RDEPENDS` to name.

To add a driver to the guarantee, add it in the contract and in
`recipes-kernel/linux/game-controller/game-controller.cfg`; the tests fail if the two
disagree, and CI fails if a board cannot deliver it.

## On-device smoke test

For Bluetooth, put the controller in pairing mode, find its address with
`wendy device bluetooth list`, then pair and trust it:

```sh
wendy device bluetooth connect <address>
```

Deploy a service with `{ "type": "input" }`. Inside that service, verify the controller
appears, inspect its stable identity, and confirm it emits events:

```sh
ls -l /dev/input/by-id
python3 - <<'PY'
from evdev import InputDevice, list_devices

for path in list_devices():
    device = InputDevice(path)
    print(path, device.name, device.uniq, sorted(device.capabilities()))
PY
```

Repeat with the same controller connected over USB. Event numbers are not stable;
applications should select a compatible device by capabilities and, when pinning is
needed, use its evdev `uniq` or `/dev/input/by-id` basename.

The `input` entitlement grants `/dev/input` and the input character-device major. The
kernel also builds `hidraw`, but `/dev/hidraw*` is a different major and is **not** part
of that entitlement, so a container cannot open one — reach for it only from the host.
