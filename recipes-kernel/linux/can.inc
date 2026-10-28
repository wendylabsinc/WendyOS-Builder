# SocketCAN: the kernel side. Required from a board's kernel bbappend when
# WENDYOS_CAN is "1", so there is no gate here. Board-neutral: every kernel
# takes the same fragment.

# THISDIR is this file's directory, so the path works from any bbappend.
FILESEXTRAPATHS:prepend := "${THISDIR}/can:"

SRC_URI += " file://can.cfg "
