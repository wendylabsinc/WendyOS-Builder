# Generic x86_64 PC distro configuration.

WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_EFI_DEBUG ?= "0"
WENDYOS_USB_GADGET ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
WENDYOS_PERSIST_JOURNAL_LOGS ?= "0"

# Commodity PCs are usually discovered over LAN rather than direct USB gadget
# networking, so do not restrict Avahi to usb0.
WENDYOS_MDNS_INTERFACES ?= ""

DISTRO_FEATURES:append = " wifi bluetooth"
