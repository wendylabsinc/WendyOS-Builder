SUMMARY = "Systemd mount unit for persistent containerd data directory"
DESCRIPTION = "Bind mounts /var/lib/containerd from /data/containerd to provide persistent \
container images, volumes, and snapshots across A/B OTA updates. Ensures containers \
and their data survive A/B partition switches."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://var-lib-containerd.mount \
    file://wendyos-rootfs-shadow-clean.sh \
    file://wendyos-rootfs-shadow-clean.service \
"
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "var-lib-containerd.mount wendyos-rootfs-shadow-clean.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-containerd.mount ${D}${systemd_system_unitdir}/var-lib-containerd.mount
    install -m 0644 ${UNPACKDIR}/wendyos-rootfs-shadow-clean.service ${D}${systemd_system_unitdir}/wendyos-rootfs-shadow-clean.service

    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-rootfs-shadow-clean.sh ${D}${sbindir}/wendyos-rootfs-shadow-clean.sh
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/var-lib-containerd.mount \
    ${systemd_system_unitdir}/wendyos-rootfs-shadow-clean.service \
    ${sbindir}/wendyos-rootfs-shadow-clean.sh \
"

RDEPENDS:${PN} = "systemd"
