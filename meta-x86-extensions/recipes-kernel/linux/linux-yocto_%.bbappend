FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:x86-wendyos = " \
    file://x86-nuc-drivers.cfg \
    "
