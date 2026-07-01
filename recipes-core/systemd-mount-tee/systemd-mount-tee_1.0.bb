SUMMARY = "Systemd mount unit for persistent OP-TEE secure storage"
DESCRIPTION = "Bind mounts /var/lib/tee from /data/tee so OP-TEE secure storage \
(PKCS#11 tokens, device keys, certificates) persists across Mender A/B OTA updates. \
Without this, the default /var/lib/tee on the rootfs would be wiped on every A/B \
partition switch, destroying the device's OP-TEE-backed cryptographic identity."
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
