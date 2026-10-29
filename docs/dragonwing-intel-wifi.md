# Intel BE200/BE202 on Dragonwing IQ8 and IQ9

The optional `intel-be202` driver package targets replacement Intel BE200/BE202
cards on the IQ-8275 EVK (IQ8) and IQ-9075 EVK (IQ9). Hardware validation covers
IQ8 with BE202; BE200 and IQ9 remain untested. The base image supplies the driver
runtime and carrier configuration; Intel modules and firmware are installed only
when requested.

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
modules from the exact kernel build, with dependencies absent from the base
image. The base image supplies cfg80211, mac80211 and bluetooth, including
their dependency closure; image acceptance checks require these installed
modules for the matching kernel. The add-on never shadows these shared stacks.
Jetson/Pi builds of the same package use
their existing Intel backport instead. The original Qualcomm radio packages
remain in the base image.

IQ kernel releases include a deterministic fingerprint of the resolved kernel
configuration as well as the existing source/patch Git identity. Config-only
changes therefore select a new matching devkit and add-on automatically. The
same release travels through the kernel, devkit, published metadata and module
vermagic; no hand-maintained ABI suffix is required.

The pinned qcom-next 7.2 kernel needs `CONFIG_IWLMLD` for these cards
(`8086:272b`) and accepts firmware c102–c106. The IQ package fetches c106 and
PNVM from the manifest's pinned linux-firmware commit and verifies their
SHA-256 hashes. Bluetooth firmware comes from the image's pinned recipe:
the shared BE200/BE202 `intel/ibt-0291-0291.sfi` and `.ddc` pair. The mapping is
documented by Intel's [BE200 firmware update](https://git.ti.com/cgit/processor-firmware/ti-linux-firmware/commit/WHENCE?id=ba1aa06f37477a702ebabf14b5753378460c9343)
and Ubuntu's [BE202 support record](https://bugs.launchpad.net/bugs/2033455/comments/8).
AX210/AX211 are outside this package's supported scope; their `ibt-0041-0041`
and `ibt-0040-0041` firmware pairs are omitted. Both redistribution notices are included.
The package is stored on `/data` for each installed kernel version. Retaining a rollback
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

The external USB1 Type-C connector uses port 1 of the same hub. Its HD3SS3220
Type-C controller detects attached peripherals and controls a separate 5 V VBUS
regulator through GPIO 3 of expander 1. The IQ8 base image includes the
`hd3ss3220` module and describes that connector, supply and hub graph. USB1 runs
as a host/source; M.2 Bluetooth remains on the hub's independent port 4.
Bluetooth enumeration alone does not verify the external connector's power.

**IQ8's Wendy USB gadget now uses USB2 (micro-USB), `a400000.usb`.** USB0
remains the recovery/fastboot port. The primary controller cannot serve the
USB0 gadget and host M.2 Bluetooth simultaneously. IQ9's gadget selection
is unchanged. External USB enumeration on the new IQ8 gadget port still needs
a cable test.

USB1 was not an enabled host port in stock WendyOS 0.20.1. On IQ8, that image
selected the primary controller's USB0 gadget path. A C922 webcam on USB1 did
not enumerate, including after manually selecting host mode, which exposed
only the root hubs. The unmodified published PR #321 image enabled the internal
hub and M.2 Bluetooth, but still lacked the external connector's Type-C/VBUS
configuration. These checks establish a pre-existing USB1 support gap.

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

USB1 host support was qualified with a directly attached Logitech C922
(`046d:085c`) on top of the published PR #321 image, using the candidate device
tree and an HD3SS3220 module built against its exact kernel devkit. The webcam
appeared in `wendy device camera list`; a 1280x720 JPEG and 300 decoded frames
passed. The driver, connector power and webcam returned automatically after a
warm reboot and a full power cycle with the webcam already attached. Physical
unplug disabled VBUS; reconnection enabled it and restored
the webcam, followed by another 30 decoded frames. Intel Bluetooth and 5 GHz
station Wi-Fi remained available. This is
functional qualification; it does not establish sustained throughput or
long-duration power-cycle reliability.

IQ9 and BE200 hardware remain untested. Repeated cold power cycles, IQ8 USB2 gadget
cable enumeration, original Qualcomm-card regression, automatic Bluetooth audio
profile selection, secure NDP, NAN application-service discovery, MLO, AP mode
and throughput/stability qualification remain outstanding.

For diagnosis, check `lspci -nnk` for `8086:272b` bound to `iwlwifi`, `lsmod`
for `iwlmld`, and `bluetoothctl list` for the USB Bluetooth controller. Inspect
`journalctl -k -b` for firmware, PCIe and USB errors. Missing Bluetooth USB
enumeration requires checking the carrier wiring described above.
