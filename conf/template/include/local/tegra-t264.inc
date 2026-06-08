# Tegra T264 (Thor) defaults (no Mender, no UEFI capsule update).
# Mirrors local/tegra.inc but explicitly sets WENDYOS_UPDATE_BOOTLOADER = "0"
# (the variable gates the Mender capsule artefact,
# wendyos.conf:73 defaults it to "1", so Thor must override it to "0").
WENDYOS_UPDATE_BOOTLOADER = "0"

# Keep the persistent /data partition in the A/B flash layout despite
# Mender being off: wendy-update needs it for OTA state
# (docs/plans/wendy-ota-update.md, Phase 1). Allocated empty at flash time
# (no <filename> in the XML), formatted and expanded on first boot.
# See tegra_partition_config.bbclass.
WENDYOS_DATA_PART = "1"

# Persistent journal logs — leave at the smart default (which tracks
# WENDYOS_MENDER from wendyos.conf). On Thor, WENDYOS_MENDER=0
# -> no /data partition -> logs are volatile (tmpfs). When Mender on Thor
# lands, the smart default will flip to "1" automatically.

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
