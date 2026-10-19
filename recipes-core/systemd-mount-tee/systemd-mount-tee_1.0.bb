SUMMARY = "Keeps OP-TEE secure storage on /config so it survives A/B updates"
DESCRIPTION = "Ships var-lib-tee.mount, which bind-mounts /var/lib/tee from /config/tee. \
/var/lib/tee holds the OP-TEE secure storage: PKCS#11 tokens, device keys and, on a \
Jetson, the fTPM's own NV. The rootfs copy of that path is replaced by every A/B update, \
so the storage needs a partition that survives the switch. The home is /config and not \
/data because an encrypted /data would hold the fTPM NV that has to unlock it. The mount \
is unconditional. On a board without encryption nothing writes there and the bind is \
simply empty."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "file://var-lib-tee.mount"
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "var-lib-tee.mount"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-tee.mount ${D}${systemd_system_unitdir}/var-lib-tee.mount
}

FILES:${PN} += "${systemd_system_unitdir}/var-lib-tee.mount"

RDEPENDS:${PN} = "systemd"
