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

For this draft PR, install its OS image first and add `--pr 321` to the driver
install command. A locally built package can instead be installed with
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
SHA-256 hashes. Bluetooth firmware
comes from the image's pinned recipe: the BE202 `ibt-0291-0291` pair and BE200
controller variants. Both redistribution notices are included.
The IQ8 package is about 3.5 MiB compressed (10.5 MiB of modules and firmware),
stored on `/data` for each installed kernel version. Retaining a rollback
kernel can retain another package; it does not consume either rootfs slot.
The general Intel firmware bundles stay out of the base image. The Jetson/Pi package's c107
firmware must not be substituted for the IQ payload.
Recheck compatibility when updating either pin.

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

## Build and hardware checks

The normal image build also exports a kernel devkit containing the selected
native modules and firmware. The driver workflow builds the installable package
from that devkit; it does not fetch another kernel or wireless backport.

Full IQ8/IQ9 image and driver-package builds passed on 2026-10-26. On IQ8
with a BE202, the lean image was OTA-installed and checked for absent Intel
modules/firmware before installing the package through the normal CLI. Tests
passed for bidirectional 64 MiB transfers on 2.4/5/6 GHz, WPA3-SAE on 6 GHz,
DNS/HTTPS, LE discovery, Bose A2DP audio and concurrent Wi-Fi traffic on
2.4/5 GHz. After a warm reboot, the package loaded automatically, Wi-Fi
reconnected and the Bose bond remained. Removal followed by reboot returned
the device to the lean base; reinstallation restored both radios. A2DP was
explicitly selected for audio; automatic profile selection and listening
confirmation remain pending. IQ9 and BE200 hardware testing remain pending.

NAN discovery and open data paths passed between IQ8/BE202 and an AGX Thor
with BE202 using `wendyos-nan`. IQ8 was tested as both initiator and responder,
with five TCP and five UDP exchanges in each direction per run. Sockets were
bound to the dedicated NAN data interfaces, preventing LAN fallback. IQ8
remained associated on 6 GHz in the first run and 5 GHz in the second. Twelve
consecutive start/stop cycles passed without kernel errors. This establishes
basic NAN transport; secure NDP, throughput and long-duration operation
remain unqualified. After OTA to the final image, the
peer TCP/UDP check also passed while IQ8 maintained 5 GHz station Wi-Fi and
streamed A2DP audio to Bose.

Actual Wendy Net NAN routing also passed between IQ8 and Thor: five IPv6 pings
with 1,200-byte payloads in each direction, with no loss. IQ8 had only the NAN
carrier enabled, no established LAN-carrier sockets, and increasing NAN data
interface counters; both boards retained 6 GHz station Wi-Fi. Thor initially
reported `NAN_PUBLISH: FAIL`, then recovered automatically. This checks routed
carrier traffic; application-service discovery and a long soak remain untested.

These carrier tests used a development agent combining
[WendyOS #2466](https://github.com/wendylabsinc/WendyOS/pull/2466) and
[#2488](https://github.com/wendylabsinc/WendyOS/pull/2488). The stock
2026.10.25 agent failed with `mldsa: invalid SignerOpts` after IQ8's fresh
ML-DSA enrollment. The OS/driver package does not supply that agent fix.

The image includes [Builder #318](https://github.com/wendylabsinc/WendyOS-Builder/pull/318):
`CONFIG_DUMMY=m`, with installed-module validation. On a fresh IQ8 boot, dummy
was initially unloaded; enabling mesh automatically loaded it and created
`wlmesh0`. Authenticated LAN and BLE-only routing each passed three IPv6 pings
without loss using the compatible agent. No manual module loading was needed.
[WendyOS #2482](https://github.com/wendylabsinc/WendyOS/pull/2482) is an alternative
loopback-based mesh identity design and was not included in these tests.

Use the [normal board build commands](../README.md), or run
`bitbake wendyos-image` in a prepared environment for either machine:
`iq-8275-evk-wendyos` or `iq-9075-evk-wendyos`.

Keep wired management connected for testing and record the card/carrier
revision, kernel release and loaded firmware version.

1. Check `lspci -nnk` for `8086:272b` bound to `iwlwifi`, `iwlmld` loaded,
   and a radio in `iw phy`. Inspect `journalctl -k -b` for probe, firmware,
   PCIe and IOMMU errors.
2. Test WPA2/WPA3 connections, DHCP/DNS, traffic in both directions, reconnect
   and repeated cold boots. Test 2.4/5/6 GHz with a suitable AP and permitted
   channels; record negotiated bandwidth and any firmware crashes.
3. Check `lsusb` and `bluetoothctl list`, then test Bluetooth scanning,
   pairing, reconnect and Wi-Fi coexistence. Missing USB enumeration requires
   checking the carrier wiring.
4. Refit the original Qualcomm card and verify Wi-Fi and Bluetooth still work.

Cold boots, WPA2-only APs, Wi-Fi 7 throughput, MLO and AP mode need
separate validation. NAN coverage is described above.
