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
# tegra-rootfs-redundancy arms NVIDIA's firmware A/B (RootfsRedundancyLevel) and
# reboots. On the systemd-boot A/B boot path (WENDYOS_TEGRA_SYSTEMDBOOT_AB = 1)
# that firmware mechanism is unused — slot selection lives in systemd-boot's own
# +tries boot counting on the ESP — and the var is unarmable from the OS on Orin
# anyway, so drop the arming service there (it would only burn a boot trying).
RDEPENDS:${PN} = " \
    ${@'tegra-flash-reboot' if ('tegra234' in d.getVar('MACHINEOVERRIDES').split(':') and (d.getVar('WENDYOS_LAYER_TREE') or '') == 'scarthgap') else ''} \
    ${@'' if (d.getVar('WENDYOS_TEGRA_SYSTEMDBOOT_AB') or '0') == '1' else 'tegra-rootfs-redundancy'} \
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