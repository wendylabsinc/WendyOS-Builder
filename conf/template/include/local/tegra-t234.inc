# Tegra T234 (Orin / Orin Nano): wendyos-update OTA on JetPack 7.2 /
# L4T R39.2.0 (blacksail). Symmetric with tegra-t264.inc (Thor).
#
# This is the JP7.2 fleet-unification path: r39.2.0 is the first JetPack 7
# line to support the Orin family alongside Thor, so all three Jetson boards
# can share one Yocto series (blacksail) and one OTA stack (wendyos-update).
# The JP6 / Mender Orin path still lives on `main` (local/tegra.inc); revert
# a board to it with `git checkout main` + re-bootstrap.

# wendyos-update OTA, replacing Mender. wendyos.conf defaults tegra234 to
# "mender"; override here. Pulls in the client + data-setup + the .wendy
# artifact (conf/distro/include/wendyos-update.inc) and implies the
# persistent /data partition — allocated empty at flash time and
# formatted/grown on first boot by wendyos-data-setup. See
# tegra_partition_config.bbclass.
WENDYOS_OTA = "wendy"

# Fixed A/B rootfs slot size: 12 GiB per slot on every build, so an OTA rootfs
# image always fits the on-device APP/APP_b partition (set at flash time, never
# re-created). ROOTFSPART_SIZE_DEFAULT is the single-slot value; the redundant
# A/B layout (USE_REDUNDANT_FLASH_LAYOUT=1, set in the machine conf) halves it,
# so 24 GiB -> 12 GiB per slot. image_types_tegra.bbclass uses the resulting
# ROOTFSPART_SIZE as APPSIZE in the generated flash layout. Strong '=' here
# (parsed via local.conf, before the upstream orin-nano.inc/agx-orin.inc '?=')
# wins. 24 GiB = 24 * 1024^3 bytes.
ROOTFSPART_SIZE_DEFAULT = "25769803776"

# The wendy rootfs is pinned to a fixed 12 GiB (wendyos-rootfs-size.inc), which
# equals this slot, so image == slot == OTA payload. Keep the ext4 a 128 MiB
# (32768 4K-block) multiple so blocks_per_group stays 32768: EDK2 Ext4Pkg
# (L4TLauncher's ext4 reader) rejects blocks_per_group != 8*blocksize with
# EFI_UNSUPPORTED and the board boot-loops. 12 GiB is already a 128 MiB
# multiple, so this is a no-op guard today. Scoped :pn-wendyos-image —
# machine-wide would round the ESP (tegra-espimage) past its 64 MiB max and
# fail the build; IMAGE_ROOTFS_ALIGNMENT also feeds TEGRA_BLBLOCKSIZE, pinned
# to its current 4 KiB so mksparse / the flash helper are unchanged.
IMAGE_ROOTFS_ALIGNMENT:pn-wendyos-image = "131072"
TEGRA_BLBLOCKSIZE:pn-wendyos-image = "4096"

# Rootfs-only swaps for now (no UEFI capsule bootloader update). The t234
# capsule path needs its own on-device verification on r39.2 — the ESRT
# entry0 + fw_class GUID must be confirmed (Thor's GUID 3c834404 is
# t264-only) — so it's a later phase mirroring Thor's Step B. Keep off.
WENDYOS_UPDATE_BOOTLOADER = "1"

# Persistent journal logs left at the smart default (tracks WENDYOS_OTA):
# WENDYOS_OTA="wendy" -> persistent on /data.

# UEFI/EFI debug build mode:
#   "0" - RELEASE (minimal UART output, production default)
#   "1" - DEBUG (verbose boot/capsule debug output)
WENDYOS_EFI_DEBUG = "0"

# DeepStream 8.0 (JetPack 7.2 / CUDA 13) — ENABLED. tegra-image.inc resolves
# WENDYOS_DEEPSTREAM=1 to the deepstream-8.0 package on blacksail, provided by
# our vendored recipe in meta-tegra-extensions-jp7 (DS8 is not yet on the
# meta-tegra-community wip-l4t-r39.2.0 branch — see scripts/check-jp7.2-upstream.sh
# for when to drop the vendored recipe). COMPATIBLE_MACHINE=(tegra), so the same
# recipe serves Orin (t234) and Thor (t264).
WENDYOS_DEEPSTREAM = "1"
