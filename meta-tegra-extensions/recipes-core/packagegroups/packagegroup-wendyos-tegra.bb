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
    tegra-rootfs-redundancy \
    setup-nv-boot-control \
    packagegroup-nvidia-container \
    "
# Only Thor's boot chain carries the boot-priority overlay (tegra-overlays.inc).
RDEPENDS:${PN}:append:tegra264 = " tegra-bootcontrol-overlay"

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

# v4l2loopback (recipe: recipes-kernel/v4l2loopback)
# provides the virtual V4L2 capture devices the agent uses for IP cameras and
# SensorLink sources. Every Tegra image requires the shared module recipe.
RDEPENDS:${PN} += "v4l2loopback"
