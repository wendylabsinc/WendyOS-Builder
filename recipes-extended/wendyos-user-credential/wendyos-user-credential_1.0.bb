SUMMARY = "Keep the wendy account entry across A/B updates"
DESCRIPTION = "/etc/shadow belongs to the root filesystem slot, so a newly \
installed image starts with a locked wendy account. This saves the password, \
its last change and the account expiry on /data whenever /etc/shadow changes \
and restores them at boot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://wendyos-user-credential.sh \
    file://wendyos-user-credential-restore.service \
    file://wendyos-user-credential-watch.service \
    "
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "wendyos-user-credential-restore.service wendyos-user-credential-watch.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-user-credential.sh ${D}${sbindir}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-user-credential-restore.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/wendyos-user-credential-watch.service ${D}${systemd_system_unitdir}/
}

RDEPENDS:${PN} = "bash coreutils grep shadow util-linux-flock util-linux-mountpoint wendyos-user"
