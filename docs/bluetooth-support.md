# Bluetooth stack support

WendyOS owns Bluetooth with the mainline Linux stack: BlueZ in userspace
(pairing, trust, reconnect, HID-over-GATT) over in-kernel transports. There
is no Wendy Bluetooth daemon, and — on boards under the contract below — no
vendor BT driver.

Every shipping image is checked against a BlueZ floor (5.80) in build CI;
the blacksail oe-core pin currently ships 5.86. The floor exists because
BlueZ 5.72 and earlier destroy and recreate the UHID input device on every
HID-over-GATT reconnect, which breaks controller hotplug expectations.

## The mainline-transport contract

`recipes-kernel/linux/wendy-bluetooth.inc` is an opt-in per-machine
contract: it requests the mainline Bluetooth core (`bluetooth.cfg`) plus a
per-BSP transport fragment, validates the post-Kconfig result, and deploys
the effective config beside the image (`wendyos-bluetooth-<machine>.config`).
`scripts/check_bluetooth_stack.py` then cross-checks that evidence with the
image manifest in CI: every `=m` symbol needs its kernel-module package, the
firmware and modprobe-blacklist packages must be present, and the vendor
driver packages must be absent.

First adopter: **Jetson Orin Nano devkit** (both storage machines). Its
RTL8822CE radio (USB `0bda:c822`) is unusable for BLE HID under NVIDIA's
out-of-tree `rtk_btusb` driver — the link drops in a ~2 s connect/drop loop
— so that driver is removed at the package level
(`conf/machine/jetson-orin-nano-devkit*-wendyos.conf`), blocked from loading
by `rtk-btusb-blacklist` (modprobe policy), and replaced by mainline
`btusb`+`btrtl` with firmware from `linux-firmware-rtl8822`
(`rtl_bt/rtl8822cu_fw.bin` + `_config.bin`).

Removing the vendor driver is still only half the swap: NVIDIA's kernel
tree marks `0bda:c822` `BTUSB_IGNORE` in btusb's device tables so
`rtk_btusb` could claim it, and with the vendor driver gone `btusb_probe()`
returns `-ENODEV` for the radio with no dmesg trace — the board simply has
no `hci0` (observed on the 0.18.1 devkit image). The kernel source patch
`0001-Bluetooth-btusb-un-ignore-Realtek-RTL8822CE-0bda-c822.patch`
(machine-gated in the jp7 tegra kernel bbappend, same override as the
transport fragment) restores the mainline `BTUSB_REALTEK |
BTUSB_WIDEBAND_SPEECH` entry for that ID.

AGX Orin and Thor intentionally keep the vendor driver until each gets its
own validated swap: enabling `btusb` while `rtk_btusb` is installed would be
a probe race on the same USB ID — and their kernels keep NVIDIA's IGNORE
entries, which the machine gating leaves untouched.

## On-device smoke test (Orin Nano)

```sh
dmesg | grep -iE 'btusb|btrtl|rtk'   # expect btusb + RTL firmware lines, zero rtk_* lines
lsmod | grep -E 'btusb|btrtl'
bluetoothctl --version               # >= 5.80
```

Then pair a controller with `wendy device bluetooth connect <address>` and
follow the game-controller smoke test in
[game-controller-support.md](game-controller-support.md). For the BLE
control channel, confirm the device still advertises the Wendy service UUID
and accepts the L2CAP (PSM 128) mTLS connection from the CLI.
