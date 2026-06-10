# Tegra T264 (Thor): wendy-update OTA (no Mender, no UEFI capsule update yet).
# WENDYOS_UPDATE_BOOTLOADER gates the Mender capsule artefact; Thor uses
# wendy-update with rootfs-only swaps for now, so keep it off.
WENDYOS_UPDATE_BOOTLOADER = "0"

# Thor runs the wendy-update OTA stack (wendyos.conf defaults tegra264 to
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

# DeepStream SDK is unavailable on r38.4.x meta-tegra (no deepstream-7.1
# recipe in that branch — only on scarthgap). Disable so that the
# WENDYOS_DEEPSTREAM-driven IMAGE_INSTALL block in tegra-image.inc adds
# nothing on Thor. The deepstream-7.1_%.bbappend itself is housed in the
# scarthgap-only meta-tegra-extensions-jp6 sub-layer, which Thor's
# bblayers.conf does not include — so it doesn't dangle here.
WENDYOS_DEEPSTREAM = "0"
