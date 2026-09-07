# SocketCAN: the kernel side. Required from a board's kernel bbappend when
# WENDYOS_CAN == "1", so nothing here needs its own gate — and no machine
# override either, since only a board that requires this file gets it.
#
# Board-neutral on purpose: the fragment below names no arch and no machine, so
# every kernel recipe in the fleet takes the same symbol set. Wiring a new board
# is the one gated require in its kernel bbappend, nothing here.
#
# On RPi the drivers are already in bcm2712_defconfig, so there the fragment only
# pins and extends the set rather than introducing it. On Tegra and x86 it is what
# brings CAN in at all.

# Bring the fragment along, so a board's bbappend does not have to know where it
# lives. ${THISDIR} is this file's directory during its own parse, not the including
# bbappend's, so the path stays right however it is required.
FILESEXTRAPATHS:prepend := "${THISDIR}/can:"

SRC_URI += " file://can.cfg "
