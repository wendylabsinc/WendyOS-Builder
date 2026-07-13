# Tegra T264 (Thor): wendyos-update OTA (no UEFI capsule update yet).
# WENDYOS_UPDATE_BOOTLOADER gates the UEFI capsule artefact; Thor uses
# wendyos-update with rootfs-only swaps for now, so keep it off.
WENDYOS_UPDATE_BOOTLOADER = "1"

# Thor runs the wendyos-update OTA stack (wendyos.conf defaults tegra264 to
# "none"; override here). This pulls in the client + data-setup + the
# .wendy artifact (conf/distro/include/wendyos-update.inc) and implies the
# persistent /data partition (no separate WENDYOS_DATA_PART needed — its
# default derives "1" from WENDYOS_OTA != "none"). The data partition is
# allocated empty at flash time and formatted/grown on first boot by
# wendyos-data-setup. See tegra_partition_config.bbclass.
WENDYOS_OTA = "wendy"

# Fixed A/B rootfs slot size: 12 GiB per slot on every build, so an OTA rootfs
# image always fits the on-device APP/APP_b partition (set at flash time, never
# re-created). ROOTFSPART_SIZE_DEFAULT is the single-slot value; the redundant
# A/B layout (USE_REDUNDANT_FLASH_LAYOUT=1, set in the machine conf) halves it,
# so 24 GiB -> 12 GiB per slot. image_types_tegra.bbclass uses the resulting
# ROOTFSPART_SIZE as APPSIZE in the generated flash layout. Strong '=' here
# (parsed via local.conf, before the upstream jetson-agx-thor-devkit.conf '?=')
# wins. 24 GiB = 24 * 1024^3 bytes. (Thor's upstream default was 50 GiB -> 25/slot.)
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

# Persistent journal logs — left at the smart default (tracks WENDYOS_OTA):
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
# recipe serves Thor (t264) and Orin (t234).
# (Was "0" in the wrynose/r38.4 era when no DeepStream recipe existed for Thor.)
WENDYOS_DEEPSTREAM = "1"
