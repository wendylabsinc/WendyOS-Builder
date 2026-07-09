SUMMARY = "WendyOS x86 driver update helper"
DESCRIPTION = "Schedules and runs feed-backed AMD/NVIDIA driver updates for x86 installer images"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://wendyos-driver-update.sh \
    file://wendyos-driver-update.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "wendyos-driver-update.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-driver-update.sh ${D}${sbindir}/wendyos-driver-update.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-driver-update.service ${D}${systemd_system_unitdir}/wendyos-driver-update.service
}

FILES:${PN} = " \
    ${sbindir}/wendyos-driver-update.sh \
    ${systemd_system_unitdir}/wendyos-driver-update.service \
    "

RDEPENDS:${PN} = "bash dnf rpm systemd"
