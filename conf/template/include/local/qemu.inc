# QEMU defaults: virtual machine, single ext4 partition, no A/B OTA.

# Volatile journal logs in tmpfs (no /data partition)
WENDYOS_PERSIST_JOURNAL_LOGS = "0"

# No UEFI bootloader updates on QEMU
WENDYOS_UPDATE_BOOTLOADER = "0"

# A VM has no USB peripheral controller, so discovery happens on the LAN, as on
# generic-x86-64. Empty WENDYOS_MDNS_INTERFACES lets avahi answer on every
# interface.
WENDYOS_USB_GADGET = "0"
WENDYOS_MDNS_INTERFACES = ""
