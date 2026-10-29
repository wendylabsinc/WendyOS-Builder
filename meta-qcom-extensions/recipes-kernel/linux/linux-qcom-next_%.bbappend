# WendyOS kernel deltas for the Dragonwing boards.
#
# USB configuration and board-scoped networking fixes. Other requirements are
# already in meta-qcom's defconfig: the container prerequisites (namespaces, cgroups,
# overlayfs, veth, bridge, netfilter masquerade, seccomp, BPF) are all present,
# and root-mount critical drivers (SCSI_UFSHCD, SCSI_UFS_QCOM, BLK_DEV_SD,
# EXT4_FS, EFI_PARTITION) are built in, so no fragment is needed for those.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

require ${@'recipes-kernel/linux/game-controller.inc' if d.getVar('WENDYOS_GAME_CONTROLLER') == '1' else ''}
require ${@'recipes-kernel/linux/driver-extensions.inc' if d.getVar('WENDYOS_DRIVER_EXTENSIONS') == '1' else ''}

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

require recipes-kernel/linux/mesh-local.inc
require recipes-kernel/linux/mesh-internet.inc

# Remote SensorLink camera and microphone endpoints need local loopback drivers.
SRC_URI:append:qcom-wendyos = " file://sensor-loopback.cfg"

# Native Intel Wi-Fi 7 support for either card fitted to the EVK's M.2 Key-E
# slot. Keep the existing ath11k stack: no out-of-tree wireless replacement is
# needed on this kernel. Uno Q also uses qcom-wendyos, so scope this to the EVKs.
SRC_URI:append:iq-8275-evk-wendyos = " file://intel-be200.cfg file://0006-iwlwifi-mld-advertise-secure-nan.patch file://0007-iwlwifi-mld-update-nan-cluster.patch"
SRC_URI:append:iq-9075-evk-wendyos = " file://intel-be200.cfg file://0006-iwlwifi-mld-advertise-secure-nan.patch file://0007-iwlwifi-mld-update-nan-cluster.patch"

# IQ8's M.2 Bluetooth USB path needs the internal hub selected and enabled;
# the external USB1 host connector also needs its Type-C controller and VBUS.
SRC_URI:append:iq-8275-evk-wendyos = " file://0005-arm64-dts-monaco-evk-enable-m2-usb-bluetooth.patch file://0008-arm64-dts-monaco-evk-enable-usb1-host-port.patch"

python __anonymous() {
    if d.getVar('MACHINE') in ('iq-8275-evk-wendyos', 'iq-9075-evk-wendyos'):
        d.appendVarFlag('do_configure', 'postfuncs', ' wendyos_check_intel_be200')
}

wendyos_check_intel_be200() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "Intel BE200/BE202: no resolved kernel config at $config"
    for symbol in CONFIG_IWLWIFI CONFIG_IWLMLD CONFIG_BT_HCIBTUSB CONFIG_BT_INTEL; do
        grep -q "^$symbol=m$" "$config" || \
            bbfatal "Intel BE200/BE202: $symbol must be modular for ${MACHINE}"
    done
}

python __anonymous() {
    if 'qcom-wendyos' in (d.getVar('MACHINEOVERRIDES') or '').split(':'):
        d.appendVarFlag('do_configure', 'postfuncs', ' wendyos_check_sensor_loopback')
}

wendyos_check_sensor_loopback() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "SensorLink loopback: no resolved kernel config at $config"
    for symbol in CONFIG_VIDEO_DEV CONFIG_VIDEOBUF2_VMALLOC; do
        grep -Eq "^$symbol=(y|m)$" "$config" || \
            bbfatal "SensorLink loopback: $symbol is disabled for ${MACHINE}"
    done
    # Match the required module package and the agent's on-demand modprobe.
    grep -q '^CONFIG_SND_ALOOP=m$' "$config" || \
        bbfatal "SensorLink loopback: CONFIG_SND_ALOOP must be modular for ${MACHINE}"
}

# Arduino Uno Q also includes this layer and uses the same pinned kernel.
# The newer callback releases its reference after the unlock label.
BLUETOOTH_LE_PENDING_PATCH = "0001-bluetooth-clean-up-rejected-pending-le-connection-qcom.patch"
require recipes-kernel/linux/bluetooth-le-pending.inc
