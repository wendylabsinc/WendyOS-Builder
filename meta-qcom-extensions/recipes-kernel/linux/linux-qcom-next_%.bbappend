# WendyOS kernel deltas for the Dragonwing boards.
#
# The USB gadget stack, and SocketCAN when it is turned on. Everything else
# WendyOS needs is already in meta-qcom's defconfig: the container prerequisites
# (namespaces, cgroups, overlayfs, veth, bridge, netfilter masquerade, seccomp,
# BPF) are all present, and root-mount critical drivers (SCSI_UFSHCD,
# SCSI_UFS_QCOM, BLK_DEV_SD, EXT4_FS, EFI_PARTITION) are built in, so no fragment
# is needed for those.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"

# SocketCAN: core, protocols and the USB/SPI adapter drivers. Board-neutral, and
# shared with the Tegra, RPi and x86 kernel bbappends. Inert while WENDYOS_CAN is
# "0", which is what this board sets today -- see the machine conf for why.
require ${@'recipes-kernel/linux/can.inc' if d.getVar('WENDYOS_CAN') == '1' else ''}
