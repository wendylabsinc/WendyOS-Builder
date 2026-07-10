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
