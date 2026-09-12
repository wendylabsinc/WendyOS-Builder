SUMMARY = "WendyOS Tegra-specific packages"
DESCRIPTION = "NVIDIA Jetson/Tegra hardware-specific packages including L4T libraries, tools, and bootloader components"
LICENSE = "MIT"

PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Only compatible with Tegra machines
COMPATIBLE_MACHINE = "(tegra)"

inherit packagegroup

SUMMARY:${PN} = "Tegra hardware support packages"
RDEPENDS:${PN} = " \
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
