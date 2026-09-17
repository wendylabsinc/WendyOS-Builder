# WendyOS kernel deltas for the Dragonwing boards.
#
# USB configuration and board-scoped networking fixes. Other requirements are
# already in meta-qcom's defconfig: the container prerequisites (namespaces, cgroups,
# overlayfs, veth, bridge, netfilter masquerade, seccomp, BPF) are all present,
# and root-mount critical drivers (SCSI_UFSHCD, SCSI_UFS_QCOM, BLK_DEV_SD,
# EXT4_FS, EFI_PARTITION) are built in, so no fragment is needed for those.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

require ${@'recipes-kernel/linux/game-controller.inc' if d.getVar('WENDYOS_GAME_CONTROLLER') == '1' else ''}

SRC_URI:append = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"

# Each board's OTG connector node already declares its gpios and vbus-supply;
# only the driver is missing. This fragment alone gets you no host port, though:
# with WENDYOS_USB_GADGET = "0" nothing forces the dwc3 glue built in.
SRC_URI:append:qcom-wendyos = " file://usb-conn-gpio.cfg"

# monaco-only: the refgen supply its USB2 HS PHY needs, and the board wiring the
# patch fixes up.
SRC_URI:append:iq-8275-evk = " \
    file://usb-refgen.cfg \
    file://0001-arm64-dts-monaco-evk-usb-fixups.patch \
    "

# quilt edits the tracked source in place and leaves it modified in the shared
# kernel tree. CONFIG_LOCALVERSION_AUTO is on here (default y, and no fragment
# we merge unsets it), so setlocalversion appends -dirty to the release string
# and to every module package name. It is not quilt's .pc/ directory that does
# it: setlocalversion checks with `git status -uno`, which ignores untracked
# files. Scoped to the boards that ship patches, so the devupstream variant
# keeps the default.
PATCHTOOL:iq-8275-evk = "git"
