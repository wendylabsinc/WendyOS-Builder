# WendyOS kernel deltas for the Dragonwing boards.
#
# Only the USB gadget stack so far. Everything else WendyOS needs is already in
# meta-qcom's defconfig: the container prerequisites (namespaces, cgroups,
# overlayfs, veth, bridge, netfilter masquerade, seccomp, BPF) are all present,
# and root-mount critical drivers (SCSI_UFSHCD, SCSI_UFS_QCOM, BLK_DEV_SD,
# EXT4_FS, EFI_PARTITION) are built in, so no fragment is needed for those.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"

# The host port and its board wiring. Ungated: refgen and the USB roles have
# nothing to do with the gadget knob. Scoped to the machine because the patch
# rewrites monaco-evk's board dtsi.
SRC_URI:append:iq-8275-evk = " file://usb-host.cfg \
                               file://0001-arm64-dts-monaco-evk-host-mode-on-usb2.patch"

# quilt leaves .pc/ in the shared kernel tree, which CONFIG_LOCALVERSION_AUTO
# then reports as -dirty in the release string and every module package name.
PATCHTOOL = "git"
