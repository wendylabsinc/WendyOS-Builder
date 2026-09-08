SUMMARY = "Bind mount the systemd-timesyncd clock state from /data"
DESCRIPTION = "Keeps systemd-timesyncd's last-known-good timestamp on the /data \
partition instead of the A/B rootfs, so the system clock stays monotonic across \
reboots and OTA slot switches on a board with no writable, battery-backed RTC."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = "file://var-lib-systemd-timesync.mount"
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "var-lib-systemd-timesync.mount"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-systemd-timesync.mount \
        ${D}${systemd_system_unitdir}/var-lib-systemd-timesync.mount
}

FILES:${PN} += "${systemd_system_unitdir}/var-lib-systemd-timesync.mount"
RDEPENDS:${PN} = "systemd"
