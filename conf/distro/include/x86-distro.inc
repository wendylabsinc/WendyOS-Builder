# Generic x86_64 PC distro configuration.

# Family defaults. They apply to any x86 machine that does not set these itself;
# the base defaults in wendyos.conf are weak (??=), so these win over them.
WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_EFI_DEBUG ?= "0"
WENDYOS_USB_GADGET ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
WENDYOS_CAN ?= "1"

DISTRO_FEATURES:append = " wifi bluetooth"
