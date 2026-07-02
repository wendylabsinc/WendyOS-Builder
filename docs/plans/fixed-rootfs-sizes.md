# Fixed rootfs sizes: flash == OTA == nightly == release

Status: IMPLEMENTED (2026-07-02) — pending build + hardware verification
Related: docs/plans/wendy-ota-update.md, docs/plans/wendyos-update-rpi.md

## Problem

The rootfs ext4 image was **content-sized** on the Jetson wendyos machines
(`IMAGE_ROOTFS_SIZE = "16384"` was only a 16 MiB floor; `du *
IMAGE_OVERHEAD_FACTOR` dominated). Consequences:

1. The image size drifted build-to-build; nightly and release images differed
   in size.
2. On Thor the on-disk APP/APP_b slots were a *fixed* 25 GiB inherited from
   upstream meta-tegra (`ROOTFSPART_SIZE_DEFAULT = 53687091200` in
   `jetson-agx-thor-devkit.conf`, halved by `tegra-common.inc`, substituted as
   `APPSIZE` by `image_types_tegra.bbclass`) — a second, independent source of
   truth the image could silently outgrow.
3. The `.wendy` OTA payload records only the actual image byte count
   (`wendyos-update` manifest `payload.size`), and the updater raw-wrote it to
   the inactive slot with no partition-capacity check — an oversized image
   failed mid-write on the device.
4. On RPi the wks layouts already used fixed 8192M rootfsA/B slots, but only
   rpi5 pinned the image size (as a floor with no ceiling), rpi3/4 were
   content-sized against 8 GiB slots, and the slots used wic `--size` (grow-on-
   overflow) instead of `--fixed-size` (fail-on-overflow).

## Invariants (now enforced)

For every wendy-OTA platform, one constant `S` per platform family:

- rootfs ext4 image size == `S`, on every build — nightly and release are
  byte-identical in size by construction;
- on-disk A/B rootfs slot size == `S` (Thor, RPi; see Orin note below);
- `.wendy` OTA `payload.size` == `S`;
- violations fail at build/pack time, and the updater refuses oversized
  payloads before writing.

| Platform family | Size | KiB | Bytes |
|---|---|---|---|
| Raspberry Pi (all) | 8 GiB | `8388608` | `8589934592` |
| NVIDIA Jetson (all) | 12 GiB | `12582912` | `12884901888` |

Binary GiB, deliberately multiples of 128 MiB (Thor's UEFI ext4-reader
alignment). Decisions locked 2026-07-02: minimum RPi media is 32 GB (all RPi
platforms, no rpi3/4 exemption); the full-size OTA write cost is accepted
(sparse-aware writing in wendyos-update is a possible later optimization).

## What was implemented

### Single source of truth

`conf/distro/include/wendyos-rootfs-size.inc`, required from
`wendyos-update.inc` (so it applies exactly where `.wendy` is produced —
`WENDYOS_OTA == "wendy"`): `WENDYOS_ROOTFS_SIZE_KB` (12 GiB, `:rpi` 8 GiB),
applied `:pn-wendyos-image` as `IMAGE_ROOTFS_SIZE` == `IMAGE_ROOTFS_MAXSIZE`
(floor == ceiling → exact size while content fits, loud `bb.fatal` when not),
with `IMAGE_ROOTFS_EXTRA_SPACE = "0"` (oe-core adds it AFTER the floor, so a
nonzero value would push every build past the ceiling) and
`IMAGE_OVERHEAD_FACTOR = "1.0"` (the pinned size is the headroom; 1.3 would
fail the build at ~77% real occupancy).

### Partitions pinned to the same constant

- **Thor** (`jetson-agx-thor-devkit-nvme-wendyos.conf`):
  `ROOTFSPART_SIZE_DEFAULT = "25769803776"` (2 x 12 GiB; the redundant layout
  halves it per slot) replaces the upstream 50 GiB default, so slot == image
  == payload exactly. Reclaimed NVMe space goes to the auto-grown data
  partition. The stale "slots are sized from the rootfs image" comment was
  corrected (they never were — APPSIZE comes from ROOTFSPART_SIZE).
- **RPi** (`meta-rpi-extensions/files/wic/rpi-wendy-ab{,-nvme,-mbr}.wks`):
  rootfsA/B switched from `--size 8192M` to `--fixed-size 8192M` so wic fails
  the build instead of silently growing a slot. rpi3/4 gain the image pin via
  the include (previously content-sized against 8 GiB slots — a real bug);
  rpi5's local floor-only `IMAGE_ROOTFS_SIZE` was removed in favor of the
  include. Minimum media noted as 32 GB in each wks header.
- **Orin** (blacksail CI builds with `WENDYOS_OTA=wendy`): images are pinned
  to 12 GiB by the include and fit the upstream slots (14+ GiB). The slots are
  NOT shrunk to 12 GiB yet — the machine confs are still dual-stack
  (mender/wendy switchable) and `flash-image-sizes.inc` owns sizing on the
  mender path; pin `ROOTFSPART_SIZE_DEFAULT` there once the confs are
  wendy-only. Until then the on-device pre-flight logs the (harmless)
  slot > payload inequality.

### Enforcement, four layers

1. **bitbake**: floor == ceiling (`get_rootfs_size` fatals on overflow); wic
   `--fixed-size` fatals if the rootfs outgrows an RPi slot.
2. **pack time** (`classes/image_types_wendy.bbclass`): `IMAGE_CMD:wendy`
   refuses to pack when the ext4 byte size != `WENDYOS_ROOTFS_SIZE_KB * 1024`.
3. **device side** (`wendyos-update` repo, branch `jo/ota-partition-preflight`):
   the engine probes the target slot's capacity (seek-end on the block device)
   before writing; payloads larger than the slot are rejected up front
   (fail-open with a warning when capacity cannot be probed, so a probe gap
   never bricks updates; warns on payload < slot).
4. **CI** (`.github/workflows/build.yml`, "Verify pinned rootfs size"): every
   matrix build (PRs, nightlies, releases — promote.yml re-tags a nightly)
   asserts the deployed ext4 size and the `.wendy` manifest `payload.size`
   equal the per-device constant.

## Verification checklist

- [ ] CI matrix build green: ext4 == payload == 12884901888 (Jetson) /
      8589934592 (RPi) on every device.
- [ ] `wendy install` a Thor: `lsblk -b` shows APP/APP_b == 12884901888.
- [ ] OTA a nightly onto that Thor, then a release onto that: all three
      rootfs sizes identical; pre-flight logs equality (no warning).
- [ ] RPi5 32 GB SD flash boots; data partition grows to fill the card.
- [ ] rpi3/4 image builds fit 8 GiB (first build with the pin enforced).
