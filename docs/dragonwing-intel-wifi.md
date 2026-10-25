# Intel BE200/BE202 on Dragonwing IQ8 and IQ9

The IQ-8275 EVK (IQ8) and IQ-9075 EVK (IQ9) images include native Intel
BE200/BE202 support for a replacement card in the M.2 Key-E slot.
Both full image builds passed on 2026-10-26, including checks of installed
modules, dependencies, firmware and licenses. IQ8 with a BE202 also passed
hardware tests: 2.4/5/6 GHz traffic in both directions, WPA3-SAE, DNS/HTTPS,
reconnect, Bluetooth LE discovery and pairing/audio with a Bose speaker.
The bond persisted through OTA and a warm reboot; the Bose's A2DP profile
was explicitly reconnected after the warm reboot.
The IQ8 USB fix below was rebuilt and OTA-tested. IQ9 and BE200 hardware
testing remain pending.

## Driver and firmware

The pinned qcom-next 7.2 kernel requires `CONFIG_IWLMLD` for these cards
(`8086:272b`). The Qualcomm defconfig enables `IWLWIFI` and `IWLMVM` but
disables `IWLMLD`. WendyOS enables the missing opmode and checks the resolved
configuration during the build.

The image installs `iwlwifi`, `iwlmld`, `btusb` and `btintel` with their
dependencies. PCI/USB modaliases load them automatically. The original
Qualcomm radio packages remain installed. Use the native driver on these
boards; the Jetson/Pi `intel-be202` system extension is not needed.

The pinned kernel accepts firmware c102–c106. `linux-firmware-iwlwifi-misc`
supplies `iwlwifi-gl-c0-fm-c0-c103.ucode` and PNVM; the driver falls back to
c103. The Jetson add-on's c107 firmware exceeds this kernel's supported range.
Recheck compatibility when updating the kernel or firmware pin.

`linux-firmware-ibt-misc` supplies the Bluetooth `intel/ibt-0291-0291.sfi`
and `.ddc` pair and other controller revisions. Both firmware packages include
license dependencies and together add about 261 MiB uncompressed.

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

Cold boots, WPA2-only APs, Wi-Fi 7 throughput, MLO, AP mode and
Wi-Fi Aware/NAN need separate validation.
