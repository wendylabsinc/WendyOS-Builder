SUMMARY = "Bind mount the systemd-timesyncd clock state from /data"
DESCRIPTION = "Keeps systemd-timesyncd's last-known-good timestamp on the /data \
partition instead of the A/B rootfs, so the system clock stays monotonic across \
reboots and OTA slot switches on a board with no writable, battery-backed RTC."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://var-lib-systemd-timesync.mount \
    file://wendyos-timesync-state.service \
    file://timesyncd-persist-clock.conf \
"
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "var-lib-systemd-timesync.mount wendyos-timesync-state.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-systemd-timesync.mount \
        ${D}${systemd_system_unitdir}/var-lib-systemd-timesync.mount
    install -m 0644 ${UNPACKDIR}/wendyos-timesync-state.service \
        ${D}${systemd_system_unitdir}/wendyos-timesync-state.service
    install -d ${D}${systemd_system_unitdir}/systemd-timesyncd.service.d
    install -m 0644 ${UNPACKDIR}/timesyncd-persist-clock.conf \
        ${D}${systemd_system_unitdir}/systemd-timesyncd.service.d/persist-clock.conf
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/var-lib-systemd-timesync.mount \
    ${systemd_system_unitdir}/wendyos-timesync-state.service \
    ${systemd_system_unitdir}/systemd-timesyncd.service.d/persist-clock.conf \
"
# OE ships timesyncd in systemd (enabled by its default PACKAGECONFIG), not a
# separate systemd-timesyncd package.
RDEPENDS:${PN} = "systemd coreutils"
