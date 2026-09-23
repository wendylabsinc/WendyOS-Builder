# Intel BE202 Wi-Fi and Bluetooth driver add-on

This add-on replaces the running kernel's cfg80211/mac80211 stack and supplies
Intel's `iwlwifi` + `iwlmld` modules. It is pinned to the Intel backport revision
in `driver.json`. Bluetooth uses the base OS's `btusb`/`btintel` drivers with
the controller firmware supplied by this add-on.

## Installation

Use a WendyOS image with driver add-on support and a published add-on matching
its kernel. With the BE202 fitted and wired management connected:

```sh
wendy device drivers list --available
wendy device drivers install intel-be202
wendy device wifi list
```

For a draft PR build, add `--pr <number>` to the driver install command after
installing its matching WendyOS PR image. An old image lacking the driver
runtime must be updated first. Future OS updates stage the add-on built for the
target kernel through the existing Wendy driver workflow.

Supported hardware: AGX Thor developer kit (NVMe) and AGX Orin developer kit
(NVMe or eMMC), using a PCIe BE202 with its USB Bluetooth function connected.
The same package is built for Raspberry Pi 5 (SD or NVMe image). The Waveshare
PCIe TO M.2 E KEY HAT+ connects to the Pi 5 PCIe FPC connector; use the SD boot
image while its single M.2 slot holds the BE202. NVMe boot needs a carrier that
can host both devices. This HAT does not provide native PCIe on a standard Pi 4
Model B, whose PCIe lane is used by its USB 3 controller. A Pi 4 BE202 build
would require different hardware, such as a Compute Module 4 carrier exposing
native PCIe. A USB-attached Wi-Fi adapter does not satisfy the PCI hardware match.

The BE202's Bluetooth function needs a separate USB 2.0 connection from the M.2
socket. A PCIe-only HAT can provide Wi-Fi but cannot expose BE202 Bluetooth.
The Thor package applies a PCIe No-Snoop workaround limited to Intel `8086:272b`
behind NVIDIA root port `10de:22d8`.

The firmware payload is fetched from the official linux-firmware repository and
verified by SHA-256. Wi-Fi firmware c107 is preferred, with c106 retained as a
fallback supported by the pinned driver. The PNVM is retained for compatibility.

The Bluetooth payload is the `ibt-0291-0291` pair requested by the BE202's
`8087:0038` USB function on the AGX Thor developer kit. Verify the same USB
identity and firmware request on each Pi carrier during hardware testing.
Both firmware notices are included: `LICENCE.iwlwifi_firmware` for Wi-Fi and
`LICENCE.ibt_firmware` for Bluetooth, as identified by upstream `WHENCE`.

The add-on activates only when PCI endpoint `8086:272b` is present. Because it
replaces the kernel's complete cfg80211/mac80211 stack, activation unloads that
stack in dependent-first order and enters through `iwlmld`; it also reloads
`btusb` after the extension's BE202 firmware becomes visible. The global
supplicant is restarted after the cfg80211 replacement, and a NetworkManager
profile active before the reload is restored by UUID. Install and upgrade it
with wired management available because activation briefly removes the managed
Wi-Fi interface.

On Pi, the onboard Broadcom `brcmfmac` module must unload before the backported
`cfg80211` can replace the kernel's wireless stack. While the BE202 add-on is
active, the onboard Wi-Fi radio is unavailable. A BE202 connection is restored
by PCI identity, independent of whether it was named `wlan0` or `wlan1`; an
onboard Wi-Fi connection is intentionally not restored. Keep Ethernet or USB
gadget management connected for installation and removal.

The package uses WendyOS's existing NetworkManager and wpa_supplicant. It does
not change either userspace package or configure Wi-Fi Aware, internet sharing,
or mesh routing. The backported kernel has NAN capabilities, but using those
requires separate userspace integration.

Do not co-install another add-on replacing cfg80211/mac80211 (including the lab
`intel-be202-nan` package). Replacement unloads are never forced; if a module is
busy, activation reports failure and a reboot may be needed. Driver removal
also requires a reboot when the stack is in use.
