# WendyOS kernel deltas for the Dragonwing boards.
#
# Only the USB gadget stack so far. Everything else WendyOS needs is already in
# meta-qcom's defconfig: the container prerequisites (namespaces, cgroups,
# overlayfs, veth, bridge, netfilter masquerade, seccomp, BPF) are all present,
# and root-mount critical drivers (SCSI_UFSHCD, SCSI_UFS_QCOM, BLK_DEV_SD,
# EXT4_FS, EFI_PARTITION) are built in, so no fragment is needed for those.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# Native game controllers: the shared Kconfig contract (the .inc says what it guarantees).
require ${@'recipes-kernel/linux/game-controller.inc' if d.getVar('WENDYOS_GAME_CONTROLLER') == '1' else ''}

SRC_URI:append = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"
