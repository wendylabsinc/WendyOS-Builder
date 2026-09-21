# Jetson Operations How-To

Operational commands and fixes for WendyOS on NVIDIA Jetson Orin devices
(Orin Nano DevKit and AGX Orin DevKit). The procedures below operate on
chip-wide Tegra234 mechanisms (UEFI variables under the L4T RootfsStatus
GUID, Mender data under `/data`) and apply to both boards unless explicitly
noted.

## CSI camera reports a firmware mismatch

### Symptom

`wendy device camera view` fails with `TEGRA_FIRMWARE_MISMATCH` and reports two
different L4T families, or `/dev/capture-isp-channel*` is absent after a raw
rootfs image was written.

### Cause

The rootfs release in `/etc/nv_tegra_release` and the boot firmware reported by
`nvbootctrl dump-slots-info` came from different JetPack/L4T families. CSI/ISP
drivers depend on matching boot firmware; raw `--rootfs-only` imaging never
updates QSPI.

### Fix

Put the supported devkit in Force Recovery mode and run full recovery (do not
pass `--rootfs-only`):

```bash
# Orin Nano P3767-0005 on P3768-0000 (NVMe)
wendy os install --device-type jetson-orin-nano

# AGX Orin P3701-0005 on P3737-0000
wendy os install --device-type jetson-agx-orin --storage nvme
# or: --storage emmc
```

Full recovery erases QSPI and all partitions on the chosen storage, including
`/data`. The CLI does not fall back automatically to raw imaging. After it
reports final `SUCCESS`, verify both commands report the same L4T family and
then retry CSI streaming:

```bash
cat /etc/nv_tegra_release
nvbootctrl dump-slots-info
ls /dev/capture-isp-channel*
wendy device camera view
```

An unknown or unparseable firmware state produces an agent warning but does not
block cameras. Capsule-based T234 boot-firmware OTA remains disabled; enabling
and qualifying it is separate follow-up work.

---

## Restore Rootfs Slot Integrity

### Symptom

`/data/device-status.sh` shows a rootfs slot as `unbootable`:

```
slot: 1,    retry_count: 0,    status: unbootable
```

This blocks OTA updates — Mender will switch to the target slot, but UEFI
firmware detects the `unbootable` status and falls back to the current slot
before Linux even boots.

### Cause

The slot was previously written to but never marked successful (e.g. after a
failed or interrupted OTA). The UEFI variable `RootfsStatusSlotB` holds a
persistent `unbootable` flag.

### Fix

Run on the Jetson as root. The write format is always:
- bytes 0–3: UEFI variable attributes (`NV=1 + BS=2 + RT=4 = 0x07`)
- bytes 4–7: status payload (`0x00000000` = normal)

**Slot B (slot index 1):**

```bash
chattr -i /sys/firmware/efi/efivars/RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9
printf '\x07\x00\x00\x00\x00\x00\x00\x00' \
  > /sys/firmware/efi/efivars/RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9
```

**Slot A (slot index 0):**

```bash
chattr -i /sys/firmware/efi/efivars/RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9
printf '\x07\x00\x00\x00\x00\x00\x00\x00' \
  > /sys/firmware/efi/efivars/RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9
```

> **Caution:** Only reset slot A while booted from slot B (and vice versa).
> Resetting the currently active slot's status mid-boot is harmless, but doing
> it on the wrong slot during a half-completed OTA can confuse the bootloader.

### Verify

```bash
/data/device-status.sh
```

Expected output after fix:

```
slot: 1,    retry_count: 0,    status: normal
```

### Notes

- `nvbootctrl mark-boot-successful` was removed in L4T 35.2.1; the efivarfs
  write above is the replacement.
- The `retry_count` stays at 0 after this fix; it increments only on actual
  boot attempts. A successful OTA will reset it to the configured maximum.
- If `/data/mender/tegra-bl-version-before` is still present after a completed
  OTA cycle, it is safe to delete: `rm /data/mender/tegra-bl-version-before`

---

## No Wi-Fi with an M.2 E-key card

### Symptom

`wendy device wifi list` reports no Wi-Fi device and `nmcli radio` shows
`WIFI-HW missing`. `lspci -nnk` lists the card (an Intel AX210 is `8086:2725`)
with no `Kernel driver in use` line. With an Intel card the Bluetooth half
(`8087:0032`) binds `btusb`, but `dmesg` reports
`Failed to load Intel firmware file intel/ibt-0041-0041.sfi`.

### Cause

Images up to 0.19.3 build no Intel or Realtek in-tree Wi-Fi driver
(`CONFIG_IWLWIFI` and `CONFIG_RTW88` unset) and ship no wireless firmware:
`/lib/firmware` holds only NVIDIA's blobs, so the MediaTek, Qualcomm, Broadcom
and Marvell drivers that are built as modules cannot start either. The kernel
command line's `firmware_class.path=/etc/firmware` comes from meta-tegra's
`KERNEL_ARGS` and is harmless: the directory does not exist and the firmware
loader falls back to `/lib/firmware`.

### Fix

Install an image built with `wifi.cfg`
(`meta-tegra-extensions-jp7/recipes-kernel/linux/linux-noble-nvidia-tegra/`)
and the firmware list in `conf/distro/include/tegra-image.inc`. Those cover
the M.2 E-key modules below.

| Module | Driver | Firmware package | Notes |
|--------|--------|------------------|-------|
| Intel AX210 / AX1675 | `iwlwifi` + `iwlmvm` | `linux-firmware-iwlwifi-ax210`, `linux-firmware-ibt-ax210` | Bluetooth over the card's USB function |
| Intel AX200 / AX1650 | `iwlwifi` + `iwlmvm` | `linux-firmware-iwlwifi-ax200`, `linux-firmware-ibt-20` | |
| Orin Nano devkit on-board RTL8822CE | NVIDIA `rtl8822ce` (out-of-tree, `/lib/modules/*/updates`) | `linux-firmware-rtl8822` | In-tree `rtw88_8822ce` is left off so the two never race |
| Realtek RTL8822BE, RTL8821CE, RTL8723DE | `rtw88_*` | `linux-firmware-rtl8822` / `-rtl8821` / `-rtl8723` | |
| MediaTek MT7921, MT7922 | `mt7921e` | `linux-firmware-mt7921` | Wi-Fi and Bluetooth blobs |
| Qualcomm QCA6390, WCN6855 (FastConnect 6900) | `ath11k_pci` | `linux-firmware-ath11k-qca6390` / `-ath11k-wcn6855` | Bluetooth firmware not shipped |
| Qualcomm QCA6174 | `ath10k_pci` | `linux-firmware-ath10k-qca6174` | |
| Broadcom BCM43602, BCM4356 | `brcmfmac` | `linux-firmware-bcm43602` / `-bcm4356-pcie` | |
| NXP/Marvell 88W8997 | `mwifiex_pcie` | `linux-firmware-pcie8997` | |

Not covered: Intel BE200/BE202 (need `iwlmld`, kernel 6.15+; see the add-on
work in PR #262), Intel CNVi parts such as AX201/AX211 (need an Intel
chipset), Realtek RTL8852/RTL8851 (`rtw89` is not enabled) and USB Wi-Fi
adapters. To add a card, enable its driver in `wifi.cfg`, add it to
`WENDYOS_WIFI_MODULES` in the kernel bbappend, and add its `linux-firmware-*`
sub-package to `tegra-image.inc`; the build fails loudly if either name is
wrong.

### Verify

```bash
dmesg | grep -E 'iwlwifi|Bluetooth: hci0'
# iwlwifi 0001:01:00.0: loaded firmware version 86.xxxx ty-a0-gf-a0-86.ucode ...
# Bluetooth: hci0: Found device firmware: intel/ibt-0041-0041.sfi
nmcli device status          # a wifi row, e.g. wlan0
wendy device wifi list
wendy device wifi connect --ssid <ssid>
```

A build that stops with `wifi.cfg: CONFIG_... did not resolve to =m` means the
NVIDIA defconfig dropped a parent of one of these drivers; fix the fragment
rather than the image list.

---
