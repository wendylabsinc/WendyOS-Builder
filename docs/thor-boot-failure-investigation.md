# Jetson AGX Thor — WendyOS boot-failure investigation

**Status:** open — root causes identified, device does **not** yet boot. One hard blocker (UEFI cannot mount the rootfs ext4) is unresolved.

**Image under test:** `nightly-20260630T155854` (= `main` @ `c7cab52`), machine `jetson-agx-thor-devkit-nvme-wendyos`.

**Symptom:** After an apparently successful flash, the Thor boot-loops and never comes up on the network. Reproduces identically with **both** the official nightly CLI **and** the dev CLI from [WendyOS#1233](https://github.com/wendylabsinc/WendyOS/pull/1233) (flashpack path).

---

## TL;DR

Both flash methods write the **same CI-built artifact**, so the fault is in the **image**, not the CLI. Everything traces back to the **2026-06-17 flip of Thor onto the experimental `blacksail` / JetPack 7.2 / L4T R39.2.0 tree** (`a4de309`, PR #130), whose own comment calls it *"an EXPERIMENT to find what breaks."* We peeled several layers:

| # | Finding | Status |
|---|---------|--------|
| 1 | Thor builds on a moving `blacksail`/`master` tree (kernel + DTB + firmware + oe-core all changed) | **Confirmed** (umbrella cause) |
| 2 | A/B **boot-control / SMD never seeded** → L4T Launcher defaults to **recovery boot** → empty recovery partition → loop | **Confirmed on-device** |
| 3 | `/data` mount hangs `sysinit.target` on Thor (reverted fix `549f08d`) | **Confirmed by code analysis** (not reached on-device) |
| 4 | **UEFI will not mount the OE-built 25.6 GB rootfs ext4** → launcher can't read `extlinux.conf` | **Unresolved — current hard blocker** |
| — | ext4 features (`orphan_file`/`metadata_csum_seed`) | **Ruled out** |
| — | rootfs GPT type (`0700` vs `8300`) | **Ruled out** |

The device currently gets: firmware → UEFI → L4T Launcher → **fails to read the kernel from the rootfs** → drops to the UEFI shell.

---

## Boot chain (Thor / T264, extlinux path)

```
BootROM → MB1 → MB2 → PSC → cpu-bootloader (UEFI, in QSPI)
        → \EFI\BOOT\bootaa64.efi  (NVIDIA L4T Launcher, on the esp partition)
        → reads /boot/extlinux/extlinux.conf from the rootfs (APP / APP_b, ext4)
        → loads /boot/Image + /boot/<dtb> + /boot/initrd
        → Linux → systemd
```

- The firmware chain (mb1, psc, mb2, **UEFI**, bpmp, etc.) is flashed to the module **QSPI**, not the NVMe (verified in the flashpack's `FileToFlash.txt`: those partitions target `/dev/block/810c5b0000.spi`).
- The NVMe holds: `esp` (FAT, launcher only), `APP`/`APP_b` (ext4 rootfs A/B), `config` (FAT), `data`, plus empty `recovery`/`*_alt` partitions.
- `extlinux.conf` and the kernel live in the **rootfs `/boot`** (recipe `l4t-launcher-extlinux.bb`), so boot depends on UEFI being able to mount the rootfs ext4.

Verified `extlinux.conf` (read from the flashed rootfs) — well-formed, no `root=` (the launcher injects it from the A/B slot):
```
DEFAULT primary
LABEL primary
  LINUX /boot/Image
  FDT /boot/tegra264-p4071-0000+p3834-0008-nv.dtb
  INITRD /boot/initrd
  APPEND ${cbootargs} … console=ttyUTC0,115200 … video=efifb:off
```

---

## Findings in detail

### 1. Experimental blacksail / JP7.2 tree (umbrella cause)

`conf/template/boards/jetson-agx-thor/repos.overrides`:
- `WENDYOS_LAYER_TREE="blacksail"` → JetPack 7.2 / L4T R39.2.0
- `meta-tegra` pinned to `wip-l4t-r39.2.0`; **oe-core, meta-openembedded, meta-virtualization all on `master`** (moving targets)
- meta-oe / meta-virt don't declare `blacksail` upstream — force-bridged via `blacksail-compat.inc`

`conf/distro/wendyos.conf:70` drops the L4T version pin entirely on blacksail. The machine conf's "JetPack 7.1 / L4T 38.4.0" comments are the **untaken `wrynose` fallback**, so the repo reads as more stable than what it ships. Every Thor nightly since 2026-06-17 is built on this tree.

Last known pre-blacksail nightly: `nightly-20260617T091232` (`ca99eda`, wrynose / JP7.1) — a useful bisection anchor.

### 2. A/B boot-control / SMD never seeded (confirmed on-device)

From the UEFI shell (`dmpstore -guid 781E084C-A330-417C-B678-38E696380CB9`):
```
RootfsStatusSlotA   = FF 00 00 00     ← uninitialized (should be 00 = normal/bootable)
RootfsStatusSlotB   = FF 00 00 00     ← uninitialized
RootfsRedundancyLevel = 01            ← A/B enabled
RootfsRetryCountMax   = 03
L4TDefaultBootMode    = 01
BootChainFwCurrent/OsCurrent = 01      ← flipped to slot B after repeated failures
```

With both slot-status entries at the erased value `0xFF`, the L4T Launcher finds **no bootable normal slot** and falls to recovery:
```
L4TLauncher: Attempting Recovery Boot
Android image header not seen
Failed to boot recovery:1 partition
```
…and the `recovery` partition is empty (never written by the flash), so it dead-ends.

**Root cause:** `scripts/make-thor-flashpack.sh` deliberately *"stops before USB"* (see its lines ~119-121: *"Only flash-images/ is flashed at stage 2 … the rcm-boot/rcm-flash workspace dirs are the host's own boot phase … we never generate them"*). NVIDIA's `initrd-flash` performs the on-device **boot-control initialization** at the end of the USB phase; the flashpack skips it, and Mender (which historically seeded slot state) was removed with nothing replacing it (`wendyos-update` is still "Phase 1"). So no code ever seeds `RootfsStatusSlot*`.

**Workaround proven on-device:** seeding the slots to `0` from the UEFI shell flips the launcher from recovery to normal (`Attempting Direct Boot`):
```
setvar RootfsStatusSlotA -guid 781E084C-A330-417C-B678-38E696380CB9 -nv -bs -rt =H"00000000"
setvar RootfsStatusSlotB -guid 781E084C-A330-417C-B678-38E696380CB9 -nv -bs -rt =H"00000000"
```

### 3. `/data` mount hangs `sysinit.target` (confirmed by code analysis)

Not observed live (boot never reached Linux), but well-evidenced. The reverted commit `549f08d` ("attempt at fixing /data mount on thor", reverted by `1b45592`) documents the exact bug in its own comments:

> On Jetson Thor / T264, udev does not emit the `/dev/disk/by-partlabel/` links even though the GPT partition name is correct.

Current (reverted-to) code on `main`:
- `recipes-core/wendyos-data-setup/files/wendyos-data-init.service` has `ConditionPathExists=/dev/disk/by-partlabel/data` → never true on Thor → the format/grow service is **skipped**, so `data` is never made into a filesystem.
- `recipes-core/wendyos-data-setup/files/data.mount` uses `What=/dev/disk/by-partlabel/data` **without `nofail`** → the backing `.device` unit never activates → the mount blocks. And `wendyos-etc-binds.service` (`Requires=data.mount`, `Before=sysinit.target`) then blocks **`sysinit.target`** → boot hangs before networking.

Smoking gun: `/config` mounts fine because its fstab entry **has `nofail`** (`LABEL=config /config vfat defaults,nofail`); `data.mount` lacks it.

### 4. UEFI cannot mount the rootfs ext4 (UNRESOLVED — current blocker)

After seeding the boot-control (step 2), the launcher now attempts a normal boot and fails to read the kernel config:
```
L4TLauncher: Attempting Direct Boot
OpenAndReadUntrustedFileToBuffer: Failed to open \boot\extlinux\extlinux.conf: Not found
L4TLauncher: Unable to process extlinux config: Not Found
L4TLauncher: Attempting Kernel Boot
ReadAndroidStyleKernelPartition: Unable to located partition
Failed to boot kernel:0 partition
```

`map -r` in the UEFI shell shows UEFI mounts the FAT partitions **and the small `data` ext4** but **not** the 25.6 GB rootfs slots:

| device | partition | mounted? |
|--------|-----------|----------|
| `FS4` / `BLK9` | `esp` (FAT) | ✅ |
| `FS2` | `config` (FAT) | ✅ |
| `FS3` | `data` (ext4, 512 MB) | ✅ |
| `BLK1` | **`APP`** (ext4, 25.6 GB) | ❌ (BLK only) |
| `BLK6` | **`APP_b`** (ext4, 25.6 GB) | ❌ (BLK only) |

Because UEFI never exposes `APP`/`APP_b` as filesystems, the launcher (which reads via the UEFI Simple File System protocol) reports `extlinux.conf: Not found`.

**What we ruled out** (each tested by editing the live disk and re-booting):
- **ext4 features** — the `data` partition mounts *with* `orphan_file` + `metadata_csum_seed`; stripping those from `APP` (and later restoring them to exactly match `data`) made **no difference** to whether UEFI mounts it. Not the cause. (Note: an earlier hypothesis that these features broke the bootloader was **wrong**; the reset-loop→recovery transition was the boot-control state, not ext4.)
- **GPT partition type** — `APP`/`APP_b` are typed `0700` (Microsoft basic data) vs `data`'s `8300` (Linux filesystem). Retyping `APP`/`APP_b` to `8300` did **not** make UEFI mount them. Not the cause.

**Remaining suspects (not yet tested):** filesystem **size** (512 MB vs 25.6 GB) or an **`mkfs.ext4` option** difference between the OE-built rootfs and a hand-made partition, or a limitation in NVIDIA's UEFI `Ext4Dxe` for this BSP. The `data` partition that mounts was created by host `mke2fs 1.47.4`; the rootfs was built by blacksail oe-core and is 50× larger.

---

## Recommended fixes / next steps

1. **Boot-control (finding 2)** — the highest-value fix. Either:
   - seed `RootfsStatusSlotA`/`B` (and mark slot A bootable) as part of the flashpack / first flash, or
   - **disable A/B redundancy on Thor** for now — set `USE_REDUNDANT_FLASH_LAYOUT_DEFAULT = "0"` in `conf/machine/jetson-agx-thor-devkit-nvme-wendyos.conf` so the launcher does a single-slot extlinux boot with no SMD dependency, until `wendyos-update` A/B lands.
2. **`/data` (finding 3)** — re-land the reverted `549f08d`: resolve the partition by scanning (not the `by-partlabel` symlink), add `nofail` to `data.mount`, and drop the `ConditionPathExists`. Confirm *why* it was reverted before re-merging.
3. **Rootfs mount (finding 4)** — the blocker. Options to investigate:
   - Compare the OE `mkfs.ext4` invocation against a stock, known-bootable L4T rootfs and match features/options; test whether a smaller or differently-built rootfs mounts.
   - Consider placing the kernel + DTB + `extlinux.conf` on the **FAT `esp`** partition (which UEFI mounts reliably) instead of the ext4 rootfs `/boot`, so boot doesn't depend on UEFI ext4 support.
   - Verify NVIDIA's T264/R39.2.0 prebuilt UEFI actually ships a working `Ext4Dxe` for large filesystems.
4. **Strategic (finding 1)** — decide whether Thor should ride the moving `blacksail`/`master` tree or be pinned to a validated snapshot / reverted to `wrynose` until JP7.2 is stabilized. Fastest regression check: flash `nightly-20260617T091232` (`ca99eda`, last wrynose build) and see if it boots.

---

## Appendix — on-device debugging notes

The device exposes an interactive **UEFI shell** on HDMI when boot fails (no serial adapter needed — `ttyUTC0 @ 115200` is the serial console if one is available). Useful commands: `map -r` (list filesystems/block devices), `dmpstore -b -guid <guid>` (paged NVRAM dump), `setvar` (edit NVRAM), `reset`.

The flashed rootfs ext4 can be inspected from a macOS host with Homebrew `e2fsprogs` (`dumpe2fs`, `debugfs`, `e2fsck`) after converting the Android-sparse `wendyos-image.ext4.simg` to raw. macOS cannot mount ext4 natively.
