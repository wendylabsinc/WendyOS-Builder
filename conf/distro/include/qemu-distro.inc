# QEMU-specific distro configuration
# This file is included when building for QEMU machines

# Disable Tegra/hardware-specific features for QEMU.
#
# Careful with "?=" in this file. It is immediate and order-dependent (BitBake's
# DataNode.eval "ques" branch re-reads the current value and keeps it if already
# set), and BitBake parses local.conf -> machine conf -> distro conf. This file is
# required from wendyos.conf line 214, so a "?=" here only ever fires for a variable
# that NOTHING set at local.conf scope, at machine scope, or earlier in
# wendyos.conf. Today that is WENDYOS_CAN alone.
#
# Removed 2026-09-07 because they were dead: WENDYOS_UPDATE_BOOTLOADER and
# WENDYOS_PERSIST_JOURNAL_LOGS (already set hard at
# conf/template/include/local/qemu.inc:7 and :4, local.conf scope) and
# WENDYOS_EFI_DEBUG (conf/machine/qemuarm64-wendyos.conf:33, machine scope).
#
# WENDYOS_USB_GADGET and WENDYOS_DEEPSTREAM below are also inert on the in-tree
# machine (qemuarm64-wendyos.conf:21 and :27 get there first). They are kept
# deliberately, as the family fallback for an out-of-tree QEMU machine that sets
# nothing -- not because they are load-bearing today.
WENDYOS_USB_GADGET ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
WENDYOS_CAN ?= "0"

# Persistent journal logs are disabled for QEMU (no /data partition, so
# var-log.mount must not be created). That is done at local.conf scope by
# conf/template/include/local/qemu.inc:4 -- see the note above for why a "?=" here
# could not do it. (A hard "=" here would take effect, since the distro conf is
# parsed after local.conf; it is simply not where that policy belongs.)

# Note: A/B OTA is not inherited for QEMU (see wendyos.conf)
# QEMU uses a simple single-partition ext4 layout without A/B partitions
