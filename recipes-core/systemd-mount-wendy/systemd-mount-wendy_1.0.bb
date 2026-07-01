SUMMARY = "Systemd mount unit for persistent wendy volume storage"
DESCRIPTION = "Bind mounts /var/lib/wendy from /data/wendy so persistent app volumes \
(created under /var/lib/wendy/volumes by the agent) live on the /data partition instead \
of the small A/B rootfs. Keeps volume data off the rootfs and surviving Mender OTA swaps."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "file://var-lib-wendy.mount"
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "var-lib-wendy.mount"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-wendy.mount ${D}${systemd_system_unitdir}/var-lib-wendy.mount
}

FILES:${PN} += "${systemd_system_unitdir}/var-lib-wendy.mount"

RDEPENDS:${PN} = "systemd"
