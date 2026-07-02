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

