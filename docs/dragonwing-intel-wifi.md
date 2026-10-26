# Intel BE200/BE202 on Dragonwing IQ8 and IQ9

The IQ-8275 EVK (IQ8) and IQ-9075 EVK (IQ9) support replacement Intel
BE200/BE202 cards through the optional `intel-be202` driver package. The base
image supplies the driver runtime and carrier configuration; Intel modules and
firmware are installed only when requested.

## Installation and payload

Update to a matching WendyOS image, keep wired management connected, then run:

```sh
wendy device drivers install intel-be202
wendy device wifi list
```

A locally built package can instead be installed with
`--file /path/to/intel-be202.raw`. Subsequent OS updates use the existing driver
workflow to stage a package matching the target kernel.

The IQ packages contain native `iwlwifi`, `iwlmld`, `btusb` and `btintel`
modules from the exact kernel build, with their dependencies. They keep the
base kernel's cfg80211/mac80211 stack. Jetson/Pi builds of the same package use
their existing Intel backport instead. The original Qualcomm radio packages
remain in the base image.

The pinned qcom-next 7.2 kernel needs `CONFIG_IWLMLD` for these cards
(`8086:272b`) and accepts firmware c102–c106. The IQ package fetches c106 and
PNVM from the manifest's pinned linux-firmware commit and verifies their
SHA-256 hashes. Bluetooth firmware comes from the image's pinned recipe:
the BE202 `ibt-0291-0291` pair and BE200 controller variants. Both redistribution notices are included.
The IQ8 package is about 3.5 MiB compressed (10.5 MiB of modules and firmware),
stored on `/data` for each installed kernel version. Retaining a rollback
kernel can retain another package; it does not consume either rootfs slot.
The general Intel firmware bundles stay out of the base image. The Jetson/Pi
package's c107 firmware must not be substituted for the IQ payload. Recheck
compatibility when updating either pin.

For NAN, c103 lacks the firmware command versions required by IWLMLD. The
IQ kernel backports two fixes from the pinned Intel backport: advertise the
secure-NAN capability needed to install management keys, and update mac80211's
cluster ID so its receive filter accepts peer discovery and data frames. The
package continues to use the native wireless stack.

## Bluetooth wiring

Intel Bluetooth needs USB 2.0; the Qualcomm card's UART connection cannot
carry it. Both EVKs route M.2 USB through internal hub port 4. On IQ8, WendyOS
selects that hub with the HS/SS routing GPIOs, releases its reset and runs the
primary USB controller as host. These settings follow
[Qualcomm's host-mode proposal](https://www.spinics.net/lists/devicetree/msg921693.html)
and are scoped to `monaco-evk.dts`.

**IQ8's Wendy USB gadget now uses USB2 (micro-USB), `a400000.usb`.** USB0
remains the recovery/fastboot port. The primary controller cannot serve the
USB0 gadget and host M.2 Bluetooth simultaneously. IQ9's gadget selection
is unchanged. External USB enumeration on the new IQ8 gadget port still needs
a cable test.

## Build and runtime requirements

The normal image build exports a kernel devkit containing the selected native
modules and firmware. The driver workflow builds the installable package from
that devkit; it does not fetch another kernel or wireless backport. Use the
[normal board build commands](../README.md) for `iq-8275-evk-wendyos` or
`iq-9075-evk-wendyos`.

Wendy Net requires a compatible agent as well as the driver package. ML-DSA
device identities need the manifest-signing support in
[WendyOS #2466](https://github.com/wendylabsinc/WendyOS/pull/2466) and catalogue
support in [#2488](https://github.com/wendylabsinc/WendyOS/pull/2488).
The current mesh implementation uses the dummy network driver for its
`wlmesh0` identity interface. The base image enables `CONFIG_DUMMY=m` and
validates that the module is installed.

## Validation status

IQ8 with BE202 has passed package installation/removal, warm reboot, Wi-Fi on
2.4/5/6 GHz, WPA3-SAE, Bluetooth A2DP with concurrent Wi-Fi, and bidirectional
Wendy Net NAN routing with a compatible development agent. IQ8/IQ9 image and
package builds passed. Detailed qualification evidence is in
[PR #321](https://github.com/wendylabsinc/WendyOS-Builder/pull/321).

IQ9 and BE200 hardware remain untested. Cold power cycles, IQ8 USB2 gadget
cable enumeration, original Qualcomm-card regression, automatic Bluetooth audio
profile selection, secure NDP, NAN application-service discovery, MLO, AP mode
and throughput/stability qualification remain outstanding.

For diagnosis, check `lspci -nnk` for `8086:272b` bound to `iwlwifi`, `lsmod`
for `iwlmld`, and `bluetoothctl list` for the USB Bluetooth controller. Inspect
`journalctl -k -b` for firmware, PCIe and USB errors. Missing Bluetooth USB
enumeration requires checking the carrier wiring described above.
