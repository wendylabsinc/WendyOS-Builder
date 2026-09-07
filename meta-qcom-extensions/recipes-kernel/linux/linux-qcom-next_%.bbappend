# WendyOS kernel deltas for the Dragonwing boards.
#
# Only the USB gadget stack so far. Everything else WendyOS needs is already in
# meta-qcom's defconfig: the container prerequisites (namespaces, cgroups,
# overlayfs, veth, bridge, netfilter masquerade, seccomp, BPF) are all present,
# and root-mount critical drivers (SCSI_UFSHCD, SCSI_UFS_QCOM, BLK_DEV_SD,
# EXT4_FS, EFI_PARTITION) are built in, so no fragment is needed for those.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"

# The sysext merge path. meta-qcom's defconfig is not enough: it builds overlayfs as a
# module and leaves squashfs without a decompressor, so an add-on image would fail to
# mount. sysext-runtime.inc turns both on.
require ${@'recipes-kernel/linux/sysext-runtime.inc' if d.getVar('WENDYOS_SYSEXT_ADDONS') == '1' else ''}
