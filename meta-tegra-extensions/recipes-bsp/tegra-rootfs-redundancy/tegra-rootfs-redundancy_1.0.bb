SUMMARY = "Arm Jetson rootfs A/B redundancy at boot"
DESCRIPTION = "One-shot boot service that enables NVIDIA rootfs A/B redundancy \
(the RootfsRedundancyLevel UEFI variable) when it is missing — the state left \
by flashing a rootfs image directly to disk instead of via tegraflash. Without \
it the firmware runs single-slot and every WendyOS OTA rolls back because the \
rootfs slot switch is a no-op. The service arms redundancy once and reboots to \
activate it; it is idempotent and guarded against reboot loops."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://wendyos-tegra-arm-rootfs-redundancy.sh \
    file://wendyos-tegra-rootfs-redundancy.service \
    "

S = "${UNPACKDIR}"

inherit systemd allarch

SYSTEMD_SERVICE:${PN} = "wendyos-tegra-rootfs-redundancy.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-tegra-arm-rootfs-redundancy.sh \
        ${D}${sbindir}/wendyos-tegra-arm-rootfs-redundancy

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-tegra-rootfs-redundancy.service \
        ${D}${systemd_system_unitdir}/
}

# nvbootctrl is guaranteed on every tegra image (meta-tegra
# MACHINE_EXTRA_RDEPENDS -> tegra-redundant-boot); the script also guards on
# its presence, so no hard RDEPENDS that would couple this to a package name.
#
# root-disk-part (data-device) is not in RDEPENDS either, on purpose. This
# recipe is allarch and data-device is MACHINE_ARCH, so naming it would put a
# per-machine package in this package's signature and rebuild it for every
# machine. The Yocto reference manual (allarch class) says such a recipe should
# not be allarch. The dependency is already guaranteed: data-device is in
# packagegroup-wendyos-base, and wendyos-image.bb fails the image build when its
# unit is missing. If the helper were missing anyway, the script does not arm
# and logs why.
RDEPENDS:${PN} = "systemd"

FILES:${PN} += " \
    ${sbindir}/wendyos-tegra-arm-rootfs-redundancy \
    ${systemd_system_unitdir}/wendyos-tegra-rootfs-redundancy.service \
    "
