# The sysext merge path: the kernel side. Required from a board's kernel bbappend
# when WENDYOS_SYSEXT_ADDONS == "1", so nothing here needs its own gate — and no
# machine override either, since only a board that requires this file gets it.
#
# Board-neutral on purpose: the fragment below names no arch and no machine.
# Wiring a new board is the one gated require in its kernel bbappend.

# Bring the fragment along, so a board's bbappend does not have to know where it
# lives. ${THISDIR} is this file's directory during its own parse, not the
# including bbappend's, so the path stays right however it is required.
FILESEXTRAPATHS:prepend := "${THISDIR}/sysext-runtime:"

SRC_URI += " file://sysext.cfg"
