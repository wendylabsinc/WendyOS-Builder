# RPi-specific distro configuration
# This file is included when building for RPi machines (MACHINEOVERRIDES
# contains 'rpi'). Mender is enabled per-machine via IMAGE_FSTYPES — RPi3
# remains non-Mender (MBR boot vs Mender-sdimg GPT default), RPi4 and RPi5
# get Mender artifact emission.

# No EFI/UEFI on RPi
WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_EFI_DEBUG ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
WENDYOS_PERSIST_JOURNAL_LOGS ?= "0"
# WiFi support
DISTRO_FEATURES:append = " wifi"
# WKS search path
WKS_SEARCH_PATH:prepend = "${TD_DISTRO_LAYERDIR}/files/wic:"

# PARTUUID defaults (overwritten at parse-time by partuuid.bbclass)
WENDYOS_BOOT_PARTUUID ?= "00000000-0000-0000-0000-000000000000"
WENDYOS_ROOT_PARTUUID ?= "00000000-0000-0000-0000-000000000000"
WENDYOS_CONFIG_PARTUUID ?= "00000000-0000-0000-0000-000000000000"
