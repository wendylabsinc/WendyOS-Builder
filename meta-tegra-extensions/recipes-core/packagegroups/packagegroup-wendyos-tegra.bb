SUMMARY = "WendyOS Tegra-specific packages"
DESCRIPTION = "NVIDIA Jetson/Tegra hardware-specific packages including L4T libraries, tools, and bootloader components"
LICENSE = "MIT"

PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Only compatible with Tegra machines
COMPATIBLE_MACHINE = "(tegra)"

inherit packagegroup

SUMMARY:${PN} = "Tegra hardware support packages"
# tegra-flash-reboot and tegra-camera-overlays ship only for scarthgap
# meta-tegra (Orin / tegra234); r38.4.x meta-tegra (Thor / tegra264) has no
# equivalent overlays in WendyOS yet (deferred per WDY-1249), so gate both
# on MACHINEOVERRIDES.
RDEPENDS:${PN} = " \
    ${@'tegra-flash-reboot' if 'tegra234' in d.getVar('MACHINEOVERRIDES').split(':') else ''} \
    ${@'tegra-camera-overlays' if 'tegra234' in d.getVar('MACHINEOVERRIDES').split(':') else ''} \
    tegra-tools-tegrastats \
    tegra-bootcontrol-overlay \
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