# RPi-specific distro configuration
# This file is included when building for RPi machines (MACHINEOVERRIDES
# contains 'rpi'). All non-QEMU RPi machines (RPi3/4/5) emit wendyos-update
# OTA artifacts via the rpi-wendy-ab*.wks wic layouts; geometry is per-machine.

# No EFI/UEFI on RPi
WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_EFI_DEBUG ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
WENDYOS_PERSIST_JOURNAL_LOGS ?= "0"
# WiFi support
DISTRO_FEATURES:append = " wifi"
# RPi .wks layouts live in meta-rpi-extensions/files/wic/
# (RPi-specific, with the rest of the RPi support). That is the location
# oe-core mandates: its default WKS_SEARCH_PATH searches <layer>/files/wic and
# its sanity checker rejects the older <layer>/wic.

# PARTUUID defaults (overwritten at parse-time by partuuid.bbclass)
WENDYOS_BOOT_PARTUUID ?= "00000000-0000-0000-0000-000000000000"
WENDYOS_ROOT_PARTUUID ?= "00000000-0000-0000-0000-000000000000"
WENDYOS_CONFIG_PARTUUID ?= "00000000-0000-0000-0000-000000000000"

