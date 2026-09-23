# Generic x86_64 PC distro configuration.

# Careful with "?=" in this file. It is immediate and order-dependent (BitBake's
# DataNode.eval "ques" branch re-reads the current value and keeps it if already
# set), and BitBake parses local.conf -> machine conf -> distro conf. wendyos.conf
# declares its base defaults with "??=", a weak default a "?=" here overrides, so
# a line below fires unless local.conf or a machine conf already set that variable
# -- and those still win over anything here.
#
# Removed 2026-09-07 because they were dead: WENDYOS_UPDATE_BOOTLOADER and
# WENDYOS_EFI_DEBUG (genericx86-64-wendyos.conf:30-31), WENDYOS_PERSIST_JOURNAL_LOGS
# (genericx86-64-wendyos.conf:39) and WENDYOS_MDNS_INTERFACES
# (conf/template/include/local/x86.inc:9, which keeps Avahi unrestricted because
# commodity PCs are discovered over LAN rather than direct USB gadget networking).
#
# WENDYOS_PERSIST_JOURNAL_LOGS is the one that actually misled: this file said "0",
# while genericx86-64-wendyos.conf:39 sets "1" at machine scope and wins.
#
# WENDYOS_USB_GADGET and WENDYOS_DEEPSTREAM below are also inert on the in-tree
# machine (local/x86.inc:8 and genericx86-64-wendyos.conf:32-33 get there first).
# They are kept deliberately, as the family fallback for an out-of-tree x86 machine
# that sets nothing -- not because they are load-bearing today.
WENDYOS_USB_GADGET ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
WENDYOS_CAN ?= "1"

DISTRO_FEATURES:append = " wifi bluetooth"
