# Intel BE200/BE202 on Dragonwing IQ8 and IQ9

The IQ-8275 EVK (`iq-8275-evk-wendyos`, IQ8) and IQ-9075 EVK
(`iq-9075-evk-wendyos`, IQ9) images include native Intel BE200/BE202 Wi-Fi
support. Fit the PCIe card in the M.2 Key-E slot in place of the supplied
Qualcomm card. Hardware validation on each EVK is still required.

## Driver and firmware

Intel lists BE200 and BE202 support from Linux 6.5 in the
[Linux wireless documentation](https://wireless.docs.kernel.org/en/latest/en/users/drivers/iwlwifi.html).
This builder pins meta-qcom `fcadf0c38a91fc77c4583d6defdf522fc9deb9da`, whose
`linux-qcom-next` recipe pins Qualcomm kernel
`d49c33864d06e9672dce57738be8851384578fcf` (`qcom-next-7.2-20260826`).

In that kernel both cards use PCI ID `8086:272b`. The BE200 and BE202 RF
configuration entries in `drivers/net/wireless/intel/iwlwifi/pcie/drv.c` are
conditional on `CONFIG_IWLMLD`. The stock Qualcomm defconfig enables
`IWLWIFI` and `IWLMVM`, but disables `IWLMLD`. A PCI alias alone therefore
does not establish usable support. The WendyOS fragment enables `IWLMLD=m`
and checks the resolved configuration after Kconfig runs.

The image requires `kernel-module-iwlwifi`, `kernel-module-iwlmld`,
`kernel-module-btusb`, and `kernel-module-btintel`. Yocto installs their
module dependencies, including cfg80211/mac80211. PCI and USB modaliases
load the drivers; no unconditional modules-load entry is needed.

The pinned kernel's `cfg/bz.c` accepts firmware core versions c102 through
c106. The existing oe-core pin (`2faf8e366df74aded7898904b72317521a08e2f6`)
uses linux-firmware 20260622, which contains
`iwlwifi-gl-c0-fm-c0-c103.ucode`, c102, and the matching PNVM. The image
requires `linux-firmware-iwlwifi-misc`, which owns these files and their
legacy firmware-path links. The driver can fall back from c106 to c103;
copying c107 from the Jetson add-on would exceed this kernel's supported
range. Recheck this pairing when either source pin changes.

`linux-firmware-ibt-misc` supplies the `intel/ibt-0291-0291.sfi` and `.ddc`
Bluetooth payloads, plus other controller revisions. Both firmware packages
depend on their upstream license packages. The existing misc package splits
are intentionally used rather than duplicating firmware downloads: together
they add about 261 MiB uncompressed with the current pin.

The Intel driver shares the native wireless stack with ath11k. The existing
Qualcomm modules and firmware remain installed so the same image can boot
with either card. The `intel-be202` system extension is for the older Jetson
and Pi kernels and should not be installed on these EVKs. Its NVIDIA root
port No-Snoop workaround does not apply to Qualcomm.

## Board requirements

Both pinned EVK device trees describe a generic `pcie-m2-e-connector` and
connect it to `pcieport0`. The image already installs `pwrseq-pcie-m2`, which
enables the slot supply and allows PCI enumeration. This is independent of
the endpoint vendor, so no Intel-specific device tree change is needed for
Wi-Fi based on the available source evidence.

Intel Bluetooth uses USB 2.0, separate from PCIe Wi-Fi; it cannot use the
Qualcomm card's UART Bluetooth connection. The IQ9 device tree identifies
USB hub port 4 as connected to the M.2 slot. The IQ8 connector graph describes
PCIe and UART, but does not establish a USB connection to the slot. Confirm
the carrier wiring and USB enumeration on both boards, especially IQ8.
Installing btusb and firmware cannot create a missing physical USB path.
Use a PCIe BE200/BE202 module, not a CNVio/CNVio2 model.

## Building

Use the normal board setup and build flow from the repository README:

```sh
make setup BOARD=dragonwing-iq8275
make build MACHINE=iq-8275-evk-wendyos

# In a separate build directory, or after switching the board setup:
make setup BOARD=dragonwing-iq9075
make build MACHINE=iq-9075-evk-wendyos
```

For an already prepared Yocto environment, the driver and package build is:

```sh
bitbake virtual/kernel linux-firmware packagegroup-wendyos-qcom
bitbake wendyos-image
```

The kernel configuration check rejects a disabled or built-in Intel module
because the image explicitly requires its module package. Strong package
dependencies make missing modules or firmware packages a build error.

## Build validation (2026-10-26)

The complete `virtual/kernel linux-firmware packagegroup-wendyos-qcom
wendyos-image` build passed for both machines, with 7,434 tasks in each build
graph. Both OTA (`.wendy`) and Qualcomm flash (`.qcomflash.tar.gz`) bundles
were produced.

| Machine | Kernel release |
| --- | --- |
| IQ-8275 EVK | `7.2.0-01467-g84ad553e23e3` |
| IQ-9075 EVK | `7.2.0-01466-g9fbb6abea92d` |

Checks against each assembled rootfs verified the four requested kernel
modules, their AArch64 ELF architecture and matching vermagic, the Intel PCI
alias, all 14 modules in their dependency closure, c103 firmware and PNVM,
the Bluetooth firmware pair, and both firmware license notices. The package
manifests also retain ath11k, WCN6855 firmware, M.2 power sequencing and the
regulatory database. Configuration guard checks, the existing kernel patch
checks, SensorLink checks and Dragonwing NPU checks passed.

These are build and image-content checks. No BE200/BE202-equipped IQ8 or IQ9
device was available for boot, radio, Bluetooth or performance testing.

## Hardware acceptance

Keep Ethernet or USB management available while testing. Power off before
replacing the M.2 card, fit suitable antennas, then boot the matching image.
Record the card model, carrier revision, kernel release and firmware version.

1. Confirm `lspci -nnk` shows `8086:272b` bound to `iwlwifi`, and inspect
   `journalctl -k -b` for firmware loads, probe failures, PCIe errors and
   firmware crashes. Confirm `iwlmld` loads and `iw phy` reports the radio.
2. Scan and connect through the usual Wendy Wi-Fi commands or NetworkManager.
   Test WPA2 and WPA3, DHCP, DNS, sustained traffic in both directions, and
   reconnect after an AP restart. Test 2.4/5/6 GHz with locally permitted
   channels and a suitable AP. Record the actual negotiated bandwidth.
3. Cold boot repeatedly, then test suspend/resume if supported by the board.
   Check kernel logs for IOMMU/DMA faults and PCIe AER errors under load.
4. Confirm `lsusb` shows the Intel Bluetooth function and `bluetoothctl list`
   reports a controller. Inspect the kernel log for the actual requested
   firmware and verify scanning, pairing, reconnect and Wi-Fi/BT coexistence.
   If USB is absent, investigate carrier wiring before changing the driver.
5. Refit the original Qualcomm card and verify Wi-Fi and Bluetooth still work.

Basic station support does not establish Wi-Fi 7 throughput, MLO, AP mode,
Wi-Fi Aware/NAN, or mesh behavior. Validate each required capability separately
with the deployed userspace, AP, firmware and regulatory domain.
