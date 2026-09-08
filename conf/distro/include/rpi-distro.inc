# RPi-specific distro configuration
# This file is included when building for RPi machines (MACHINEOVERRIDES
# contains 'rpi'). All non-QEMU RPi machines (RPi3/4/5) emit wendyos-update
# OTA artifacts via the rpi-wendy-ab*.wks wic layouts; geometry is per-machine.

# Careful with "?=" in this file. It is immediate and order-dependent (BitBake's
# DataNode.eval "ques" branch re-reads the current value and keeps it if already
# set), and BitBake parses local.conf -> machine conf -> distro conf. wendyos.conf
# declares its base defaults with "??=", a weak default a "?=" here overrides, so
# a line below fires unless local.conf or a machine conf already set that variable
# -- and those still win over anything here.
#
# Removed 2026-09-07 because they were dead: WENDYOS_UPDATE_BOOTLOADER and
# WENDYOS_EFI_DEBUG (already set at conf/machine/include/
# raspberrypi-common-wendyos.inc:25-26, machine scope) and
# WENDYOS_PERSIST_JOURNAL_LOGS (already set hard at
# conf/template/include/local/rpi-blacksail.inc:4, local.conf scope, which every
# RPi board template requires -- note the "?=" at raspberrypi-common-wendyos.inc:30
# is itself dead for the same reason).
#
# WENDYOS_DEEPSTREAM below is also inert on every in-tree machine
# (raspberrypi-common-wendyos.inc:27 gets there first). It is kept deliberately, as
# the family fallback for an out-of-tree RPi machine that sets nothing -- not
# because it is load-bearing today.
WENDYOS_DEEPSTREAM ?= "0"
WENDYOS_CAN ?= "1"
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

