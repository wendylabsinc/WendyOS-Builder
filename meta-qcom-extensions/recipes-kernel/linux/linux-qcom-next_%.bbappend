# WendyOS kernel deltas for the Dragonwing boards.
#
# The USB gadget stack, and SocketCAN when it is turned on. Everything else
# WendyOS needs is already in meta-qcom's defconfig: the container prerequisites
# (namespaces, cgroups, overlayfs, veth, bridge, netfilter masquerade, seccomp,
# BPF) are all present, and root-mount critical drivers (SCSI_UFSHCD,
# SCSI_UFS_QCOM, BLK_DEV_SD, EXT4_FS, EFI_PARTITION) are built in, so no fragment
# is needed for those.
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

# The QCA8081 switches its host interface with copper speed: phylink must offer
# both serial modes or a sub-2.5G partner never links, and must see a failed
# SerDes reconfiguration rather than a false link-up.
SRC_URI:append:qcom-wendyos = " file://0002-net-stmmac-qcom-ethqos-advertise-serdes-interfaces.patch file://0003-net-stmmac-propagate-platform-mac-finish-errors.patch"

# dwc3-qcom over-frees a managed software node when it tears the xHCI down to
# change role, leaving the controller with neither an xHCI nor a UDC until the
# next boot. Reproduced on both boards: every role-switching port reaches it.
SRC_URI:append:qcom-wendyos = " file://0004-Revert-usb-dwc3-qcom-skip-phy-management-swnode.patch"

# quilt edits the tracked source in place and leaves it modified in the shared
# kernel tree. CONFIG_LOCALVERSION_AUTO is on here (default y, and no fragment
# we merge unsets it), so setlocalversion appends -dirty to the release string
# and to every module package name. It is not quilt's .pc/ directory that does
# it: setlocalversion checks with `git status -uno`, which ignores untracked
# files. A machine override, so it reaches the devupstream variant as well.
PATCHTOOL:qcom-wendyos = "git"

# SocketCAN: core, protocols and the USB/SPI adapter drivers. Board-neutral, and
# shared with the Tegra, RPi and x86 kernel bbappends. Inert while WENDYOS_CAN is
# "0", which is what this board sets today -- see the machine conf for why.
require ${@'recipes-kernel/linux/can.inc' if d.getVar('WENDYOS_CAN') == '1' else ''}
