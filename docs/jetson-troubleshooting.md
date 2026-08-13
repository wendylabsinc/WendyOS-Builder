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

## Device is invisible to Wendy Cloud on an LTE / carrier uplink

### Symptom

The device vanishes from `wendy cloud discover` and `wendy cloud device shell`
fails — but it is **not** offline. `wendyos-agent` is running, the link is up,
DHCP has a lease, ping and traceroute succeed, and other software on the box
keeps using the network normally. The agent retries every 90s forever:

```
broker connection failed, reconnecting  ... authentication handshake failed: EOF  backoff:90
cloud flusher: flush failed             ... authentication handshake failed: EOF
mesh roster sync failed                 ... DeadlineExceeded
```

It does **not** take an LTE-only site to hit this. `99-interface-metrics.conf`
gives ethernet metric 100 against WiFi's 300, so plugging an LTE modem into
`eth0` moves cloud egress onto it even with WiFi up and healthy — LAN/mDNS
management keeps working, which is why the device looks fine to anyone on site
and dead to everyone else.

### Cause

The carrier path's MTU is below 1500 and it drops the ICMP "fragmentation
needed" replies Path MTU Discovery depends on. PMTUD fails silently: small
packets pass, large ones are black-holed with no error.

TCP connects fine. The first *large* packet is a TLS ClientHello — ~1556 bytes,
since a TLS 1.3 post-quantum key share is over 1.2 KB by itself — and it is
never delivered, so every TLS connection hangs until it times out.

### Fix

Shipped since this was found: `/etc/sysctl.d/99-wendyos-pmtu.conf` sets
`net.ipv4.tcp_mtu_probing = 1`, so the kernel searches for a working MSS when it
detects a black hole. On an image that predates it, apply by hand:

```bash
printf 'net.ipv4.tcp_mtu_probing = 1\n' > /etc/sysctl.d/99-wendy-pmtu.conf
sysctl -p /etc/sysctl.d/99-wendy-pmtu.conf
```

That drop-in lives on the running A/B slot and is **lost on the next OS update** —
which is why the real fix ships in the image. For UDP/QUIC, which probing does
not cover, clamp the connection on sites known to be behind a carrier link:

```bash
nmcli connection modify "<profile>" 802-3-ethernet.mtu 1400
nmcli connection down "<profile>" && nmcli connection up "<profile>"
```

### Verify

```bash
sysctl net.ipv4.tcp_mtu_probing          # expect 1
curl -sS --interface eth0 --max-time 20 -o /dev/null -w '%{http_code}\n' https://api.ipify.org
```

The device rejoins `wendy cloud discover` on its own next retry — no agent
restart needed.

### Notes

- **`ping -M do` cannot be used to measure PMTU here.** BusyBox `ping` has no
  `-M` flag, so every rung returns "invalid option" and reads as a failure —
  including over a perfectly healthy link, which looks like a catastrophic MTU
  problem and sends you the wrong way. Probe with `curl --interface <iface>`
  while stepping the link MTU (`ip link set eth0 mtu N`) instead.
- `nc -z` also misreports on this image; it failed against endpoints `curl`
  reached over the same interface.
- Measured on a Jetson Orin Nano on a TELUS LTE modem (2026-08-13, WDY-2443):
  usable path MTU 1430, link at 1500, HTTPS dead at 1440+ and fine at 1430. With
  probing enabled, HTTPS succeeds at MTU 1500 in ~4s.
- Small packets succeeding is the tell. If ping works and TLS hangs, suspect
  this before suspecting the agent.

---
