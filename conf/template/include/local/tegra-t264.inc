# Tegra T264 (Thor): wendyos-update OTA (no Mender, no UEFI capsule update yet).
# WENDYOS_UPDATE_BOOTLOADER gates the Mender capsule artefact; Thor uses
# wendyos-update with rootfs-only swaps for now, so keep it off.
WENDYOS_UPDATE_BOOTLOADER = "0"

# Thor runs the wendyos-update OTA stack (wendyos.conf defaults tegra264 to
# "none"; override here). This pulls in the client + data-setup + the
# .wendy artifact (conf/distro/include/wendyos-update.inc) and implies the
# persistent /data partition (no separate WENDYOS_DATA_PART needed — its
# default derives "1" from WENDYOS_OTA != "none"). The data partition is
# allocated empty at flash time and formatted/grown on first boot by
# wendyos-data-setup. See tegra_partition_config.bbclass.
WENDYOS_OTA = "wendy"

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
