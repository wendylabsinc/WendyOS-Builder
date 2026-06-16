SUMMARY = "Systemd mount units for persistent wendy data directories"
DESCRIPTION = "Bind mounts /var/lib/wendy from /data/wendy and /var/lib/wendy-agent \
from /data/wendy-agent to provide persistent agent state across Mender OTA updates. \
Ensures wendy-agent data survives A/B partition switches."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "file://var-lib-wendy.mount \
           file://var-lib-wendy-agent.mount"
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "var-lib-wendy.mount var-lib-wendy-agent.mount"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-wendy.mount ${D}${systemd_system_unitdir}/var-lib-wendy.mount
    install -m 0644 ${UNPACKDIR}/var-lib-wendy-agent.mount ${D}${systemd_system_unitdir}/var-lib-wendy-agent.mount
}

FILES:${PN} += "${systemd_system_unitdir}/var-lib-wendy.mount \
                ${systemd_system_unitdir}/var-lib-wendy-agent.mount"

RDEPENDS:${PN} = "systemd"
