# WendyOS kernel deltas for the Dragonwing boards.
#
# USB only so far: the gadget stack, and the micro-AB socket further down.
# Everything else WendyOS needs is already in meta-qcom's defconfig: the
# container prerequisites (namespaces, cgroups, overlayfs, veth, bridge,
# netfilter masquerade, seccomp, BPF) are all present, and root-mount critical
# drivers (SCSI_UFSHCD, SCSI_UFS_QCOM, BLK_DEV_SD, EXT4_FS, EFI_PARTITION) are
# built in, so no fragment is needed for those.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

require ${@'recipes-kernel/linux/game-controller.inc' if d.getVar('WENDYOS_GAME_CONTROLLER') == '1' else ''}

SRC_URI:append = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"

# The micro-AB socket: its connector driver, the reference regulator the USB2 HS
# PHY needs, and the board wiring the patch fixes up. Ungated, unlike
# usb-gadget.cfg above.
#
# Ungated is not the same as independent. CONFIG_USB_DWC3_QCOM is
# "default USB_DWC3" but also "depends on USB_QCOM_EUD || !USB_QCOM_EUD", and
# the defconfig carries USB_QCOM_EUD=m with no USB_DWC3_QCOM line, so it settles
# at m. Only usb-gadget.cfg forces both to y. With WENDYOS_USB_GADGET = "0" the
# dwc3 glue is a module nothing installs, neither controller probes, and this
# fragment on its own does not get you the host port.
#
# Machine-scoped because the patch rewrites monaco-evk's board dtsi.
SRC_URI:append:iq-8275-evk = " \
    file://usb-host.cfg \
    file://0001-arm64-dts-monaco-evk-usb-fixups.patch \
    "

# quilt edits the tracked .dtsi in place and leaves it modified in the shared
# kernel tree. CONFIG_LOCALVERSION_AUTO is on here (default y, and no fragment
# we merge unsets it), so setlocalversion appends -dirty to the release string
# and to every module package name. It is not quilt's .pc/ directory that does
# it: setlocalversion checks with `git status -uno`, which ignores untracked
# files. Scoped to the machine that ships the patch, so the other qcom machines
# and the devupstream variant keep the default.
PATCHTOOL:iq-8275-evk = "git"
