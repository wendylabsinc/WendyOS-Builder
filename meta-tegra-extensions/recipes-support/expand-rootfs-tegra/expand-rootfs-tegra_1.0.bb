SUMMARY = "First-boot rootfs auto-expansion for non-Mender Tegra machines"
DESCRIPTION = "Expands the APP (root) partition and grows the filesystem on first \
boot so the rootfs fills the whole disk. Tegraflash writes a GPT sized for \
TEGRA_EXTERNAL_DEVICE_SECTORS, so on a larger NVMe the remaining space is \
otherwise unpartitioned and unusable. Only for machines without the Mender \
stack (e.g. Thor): on Mender machines the A/B + /data layout owns the disk \
and mender-growfs-data expands /data instead."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://expand-rootfs.sh \
    file://expand-rootfs.service \
"

S = "${UNPACKDIR}"

inherit systemd

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/expand-rootfs.sh ${D}${sbindir}/expand-rootfs.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/expand-rootfs.service ${D}${systemd_system_unitdir}/expand-rootfs.service
}

FILES:${PN} += " \
    ${sbindir}/expand-rootfs.sh \
    ${systemd_system_unitdir}/expand-rootfs.service \
"

SYSTEMD_SERVICE:${PN} = "expand-rootfs.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "bash coreutils util-linux parted e2fsprogs-resize2fs udev gptfdisk"

COMPATIBLE_MACHINE = "tegra"
