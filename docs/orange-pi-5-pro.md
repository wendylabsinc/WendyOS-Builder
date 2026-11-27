# Orange Pi 5 Pro

The Xunlong Orange Pi 5 Pro (Rockchip RK3588S) builds as `MACHINE =
"orangepi-5-pro-wendyos"` (`BOARD=orange-pi-5-pro`, device id `orange-pi-5-pro`).
One `.wic` image boots from microSD, eMMC or NVMe, with wendyos-update A/B OTA
through U-Boot.

```bash
make setup BOARD=orange-pi-5-pro
make build MACHINE=orangepi-5-pro-wendyos
```

## Layers and versions

- [meta-rockchip](https://git.yoctoproject.org/meta-rockchip) (master) and
  [meta-arm](https://git.yoctoproject.org/meta-arm) (blacksail), pinned in
  `scripts/upstream-repos.env`. Only the Rockchip boards layer them.
- `meta-rockchip-extensions` holds the WendyOS parts: U-Boot, kernel, boot
  script, A/B layout and firmware.
- Kernel: oe-core's `linux-yocto` 7.2 from the arm64 defconfig. The Ethernet
  controller (Motorcomm YT6801) first shipped in Linux 7.0.
- U-Boot: oe-core's v2026.07 with Rockchip's DDR init and TF-A blobs (rkbin).
- The board DTS first shipped in Linux 7.3. The kernel and U-Boot carry the four
  upstream DTS commits as backports, and U-Boot carries the board itself
  (`orangepi-5-pro-rk3588s_defconfig`), which is not upstream yet.

## Boot

The BootROM loads `idbloader.img` (DDR init + SPL) from eMMC, then from microSD.
The board has no SPI NOR: it shares its pins with the eMMC socket. SPL loads
`u-boot.itb` from the same disk.

U-Boot boots the first disk whose boot partition has `wendyos-rockchip.scr`:
microSD, then eMMC, then NVMe. An inserted microSD card always wins, so a freshly
flashed card recovers a board whose eMMC or NVMe no longer boots. The script name
is specific to the family, so a Raspberry Pi card's `boot.scr` is never run.

The image needs a disk of at least 32 GB: it holds two 8 GiB root file system
slots.

| Offset / partition | Content |
|---|---|
| 32 KiB (raw) | `idbloader.img` |
| 8 MiB (raw) | `u-boot.itb` |
| p1 `boot` (FAT) | `wendyos-rockchip.scr`, `uboot.env`, `uboot-backup.env` |
| p2 `config` (FAT) | first-boot provisioning seed |
| p3 `rootfsA`, p4 `rootfsB` (ext4) | the two OTA slots, each with `/boot/Image` and the DTB |
| p5 `data` (ext4) | `/data`, grown to fill the disk on first boot |

**NVMe.** The BootROM cannot read NVMe, so U-Boot must come from eMMC or from a
microSD card. U-Boot boots the first disk that has the script, so whichever of
them carries U-Boot must hold the loaders only: for example
`dd if=idbloader.img of=/dev/sdX seek=64` and
`dd if=u-boot.itb of=/dev/sdX seek=16384`, both from the build's deploy folder.

**Vendor bootloaders.** An eMMC module with Orange Pi OS on it boots its own
U-Boot first. Remove the module, or erase its first 16 MiB, before booting
WendyOS from microSD.

## OTA

`wendyos-rockchip.scr` is the shared WendyOS A/B script
(`recipes-bsp/wendyos-boot-ab`) with a Rockchip tail. It loads the kernel and the
DTB from the selected slot and boots with `panic=10 rootwait=60`, so a trial slot
that panics or never finds its root resets into the fall-back instead of
hanging. The environment is `uboot.env` on the boot partition of the disk that
booted, 0x8000 bytes (`WENDYOS_UBOOT_ENV_SIZE`, equal to `/etc/fw_env.config` and
U-Boot's `CONFIG_ENV_SIZE`). The script keeps a byte copy in `uboot-backup.env`
and restores a missing or damaged `uboot.env` from it, so the board keeps its
committed slot. If both are lost it boots slot A and writes fresh copies. The
connector is `ubootenv`, the same as on the Raspberry Pi. OTA never rewrites the
loaders or the script, so the paths it loads (`/boot/Image`,
`/boot/rk3588s-orangepi-5-pro.dtb`) and the env size must not change.

## Console

The debug UART (`ttyS2`, 1500000 baud, 3.3 V) is on the 40-pin header: pin 8 TX,
pin 10 RX, pin 6 GND. The USB adapter must support 1.5 Mbaud (FT232R, CP2102N or
CH343 do; a PL2303 garbles it). Release images keep
it silent: the kernel console is the HDMI VT, which shows output only once the
display driver (a module) loads, so an early boot failure on a release image is
visible on neither HDMI nor the UART. Debug builds (`WENDYOS_DEBUG_UART
= "1"`, as in CI PR builds and `bootstrap.sh --debug`) add the serial console
and login.

## Hardware

| Part | Support |
|---|---|
| Ethernet | Motorcomm YT6801 on PCIe (`dwmac-motorcomm`) |
| Wi-Fi / Bluetooth | AMPAK AP6256 (`brcmfmac`, `hci_bcm`); firmware from `ampak-ap6256-firmware`, WPA2 and WPA3 |
| GPU | Mali-G610 (`panthor`), firmware `linux-firmware-mali-csffw-arch108` |
| NPU | `rocket` accel driver |
| Audio | ES8388 codec: headphone jack and onboard microphone. The kernel carries the codec's shared-LRCK and mic-bias fixes, and `alsa-state` sets the mixer defaults |
| Storage | microSD, eMMC module, M.2 NVMe |
| RTC | HYM8563 |
| USB gadget | none: the USB-C port is power only |

## Licensing

The rkbin DDR init and TF-A blobs (`LicenseRef-Rockchip-rkbin`), the AP6256
NVRAM and Bluetooth patch (`LicenseRef-ampak-ap6256-CLOSED`, see its
`NOTICE.ap6256`) are proprietary. Review them before shipping a commercial image.

The Wi-Fi firmware is Raspberry Pi's build for the same chip (the Pi 400's
BCM43456), under the Synaptics licence (`synaptics-killswitch`, as on the Pi).
The AP6256's own 2017 firmware ran the WPA handshake itself, and that handshake
never completed against WPA2/WPA3 routers.
