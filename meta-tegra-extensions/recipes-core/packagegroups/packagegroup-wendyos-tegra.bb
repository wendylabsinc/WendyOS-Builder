SUMMARY = "WendyOS Tegra-specific packages"
DESCRIPTION = "NVIDIA Jetson/Tegra hardware-specific packages including L4T libraries, tools, and bootloader components"
LICENSE = "MIT"

PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Only compatible with Tegra machines
COMPATIBLE_MACHINE = "(tegra)"

inherit packagegroup

SUMMARY:${PN} = "Tegra hardware support packages"
# tegra-flash-reboot ships ONLY on scarthgap meta-tegra (Orin / tegra234 /
# JP6). Neither Thor (tegra264) nor the JP7.2/blacksail tree has the recipe
# (blacksail's tegra-flash-init does not RDEPEND on it), so gate on BOTH the
# SoC and the scarthgap layer tree — a bare tegra234 check would wrongly pull
# it on blacksail Orin ("Nothing PROVIDES tegra-flash-reboot").
RDEPENDS:${PN} = " \
    ${@'tegra-flash-reboot' if ('tegra234' in d.getVar('MACHINEOVERRIDES').split(':') and (d.getVar('WENDYOS_LAYER_TREE') or '') == 'scarthgap') else ''} \
    tegra-tools-tegrastats \
    tegra-bootcontrol-overlay \
    tegra-rootfs-redundancy \
    setup-nv-boot-control \
    packagegroup-nvidia-container \
    "

# Conditional UEFI capsule package installation
# Controlled by WENDYOS_UPDATE_BOOTLOADER
RDEPENDS:${PN} += " \
    ${@oe.utils.ifelse( \
        d.getVar('WENDYOS_UPDATE_BOOTLOADER') == '1', \
        ' \
            tegra-uefi-capsules \
            bootloader-update \
        ', \
        '' \
        )} \
    "

# v4l2loopback (recipe: meta-tegra-extensions-jp7/recipes-kernel/v4l2loopback)
# provides the virtual V4L2 capture devices the WendyAgent device agent uses
# for IP-camera container parity (WDY-2430). It only exists in the blacksail
# (JP7.2) layer tree, but every current Tegra board builds blacksail, so an
# unconditional RDEPENDS here is safe.
RDEPENDS:${PN} += "v4l2loopback"