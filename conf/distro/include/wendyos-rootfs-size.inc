# Fixed rootfs image size — the single source of truth for the wendy OTA
# stack. Required from wendyos-update.inc,
# so it applies exactly where the .wendy artifact is produced
# (WENDYOS_OTA == "wendy": Thor, RPi3/4/5, Orin).
#
# The rootfs ext4, the on-disk A/B slot, and the .wendy OTA payload must all
# be EXACTLY this size on every build — nightly and release artifacts are
# byte-identical in size by construction, and an image can never outgrow the
# slot it is written to (the on-device slot is fixed at flash time and never
# re-partitioned; wendyos-update raw-writes the payload into it). The
# partition layouts are pinned to the same values: all Jetson (Orin + Thor)
# via ROOTFSPART_SIZE_DEFAULT in tegra-t234.inc / tegra-t264.inc (24 GiB ->
# redundant //2 -> 12 GiB per slot), RPi via the rootfsA/B --fixed-size in
# rpi-wendy-ab*.wks. wendyos-update also refuses payloads larger than the
# target slot as a last line of defense (blockdev capacity pre-check).
#
# Mechanism (oe-core image.bbclass get_rootfs_size, all units KiB):
#   floor    IMAGE_ROOTFS_SIZE      content below this builds to exactly it
#   ceiling  IMAGE_ROOTFS_MAXSIZE   content above this FAILS the build
# With floor == ceiling the size is pinned: growth past the limit is a loud
# build failure, never a silently bigger image. EXTRA_SPACE must be 0 — it is
# added AFTER the floor is applied and would push every build past the
# ceiling. The fixed size itself is the free-space headroom.
#
# Values must stay multiples of 128 MiB (131072 KiB): all Jetson align the
# image to full 32768-block ext4 groups for NVIDIA's UEFI ext4 reader (see
# tegra-t234.inc / tegra-t264.inc), and both sizes are then no-op aligned.
WENDYOS_ROOTFS_SIZE_KB = "12582912"
WENDYOS_ROOTFS_SIZE_KB:rpi = "8388608"

# Generic x86 A/B (genericx86-ab.wks): 14 GiB/slot. x86 bakes the NVIDIA compute
# stack (open kmod + proprietary userspace + container toolkit + full
# linux-firmware), so the rootfs is ~12.1 GiB and needs more headroom than both
# the 8 GiB RPi and the 12 GiB Jetson slot — 12 GiB failed the floor==ceiling
# guard. 14 GiB (112 * 128 MiB) leaves ~1.9 GiB of growth room. floor==ceiling
# means the build fails loudly if the rootfs outgrows this — bump it here (keep it
# a multiple of 128 MiB = 131072 KiB) if that happens again. x86 requires this
# include directly from x86-image.inc (Phase 1 is OTA=none, so wendyos-update.inc
# does not pull it in yet).
WENDYOS_ROOTFS_SIZE_KB:x86-wendyos = "14680064"

# Expose it to wic so the RPi A/B slots derive their --fixed-size straight from
# this one constant (rpi-wendy-ab*.wks: `--fixed-size ${WENDYOS_ROOTFS_SIZE_KB}K`
# — wic reads a K suffix as KiB, so slot == the pinned image size exactly, with
# no duplicated magic number to drift). Harmless on Jetson (tegraflash, no wic).
WICVARS:append = " WENDYOS_ROOTFS_SIZE_KB"

# Scoped :pn-wendyos-image — machine-wide sizing breaks tegra-espimage and
# the initramfs images (same scoping as the rest of this stack).
IMAGE_ROOTFS_SIZE:pn-wendyos-image = "${WENDYOS_ROOTFS_SIZE_KB}"
IMAGE_ROOTFS_MAXSIZE:pn-wendyos-image = "${WENDYOS_ROOTFS_SIZE_KB}"
IMAGE_ROOTFS_EXTRA_SPACE:pn-wendyos-image = "0"

# The default 1.3 du multiplier would fail the build at ~77% real occupancy
# for no benefit — the pinned size already provides the headroom.
IMAGE_OVERHEAD_FACTOR:pn-wendyos-image = "1.0"

# Cancel dnf's rootfs headroom on the pinned image. When package management is on
# (x86: WENDYOS_ENABLE_PACKAGE_MANAGEMENT=1 -> dnf in the image), oe-core's
# rootfs_rpm.bbclass does `IMAGE_ROOTFS_EXTRA_SPACE:append = " + 102400"` (100 MiB
# of rpm/dnf working space). That append lands after the "0" above, and any
# non-zero EXTRA_SPACE breaks floor==ceiling (the ext4 must equal the fixed slot,
# so +100 MiB pushes it past the ceiling and fails do_image). The fixed slot
# already carries GiBs of slack, so the extra is redundant — subtract it back to
# net zero. Guarded on dnf, so it is a no-op on RPi/Jetson (no package management,
# so rootfs_rpm never added it). EXTRA_SPACE is evaluated as arithmetic, so
# "0 + 102400 - 102400" = 0.
IMAGE_ROOTFS_EXTRA_SPACE:append:pn-wendyos-image = "${@' - 102400' if bb.utils.contains('PACKAGE_INSTALL', 'dnf', True, False, d) else ''}"

