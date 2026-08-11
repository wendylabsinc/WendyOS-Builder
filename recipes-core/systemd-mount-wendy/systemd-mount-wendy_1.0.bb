SUMMARY = "Systemd mount units for state that must survive an A/B OTA swap"
DESCRIPTION = "Bind mounts state that must outlive an A/B OTA swap from the /data \
partition instead of the small A/B rootfs: /var/lib/wendy for persistent app volumes \
(created under /var/lib/wendy/volumes by the agent), /var/lib/bluetooth for BlueZ \
pairing state, which the device would otherwise forget on every update, and \
/var/lib/systemd/timesync for systemd-timesyncd's last-known-good clock, without which \
an RTC-less board comes up months in the past after every OTA."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://var-lib-wendy.mount \
    file://var-lib-bluetooth.mount \
    file://wendyos-bluetooth-state.service \
    file://bluetooth-persist-state.conf \
    file://var-lib-systemd-timesync.mount \
    file://wendyos-timesync-state.service \
    file://timesyncd-persist-clock.conf \
"
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "var-lib-wendy.mount var-lib-bluetooth.mount wendyos-bluetooth-state.service \
                         var-lib-systemd-timesync.mount wendyos-timesync-state.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-wendy.mount ${D}${systemd_system_unitdir}/var-lib-wendy.mount
    install -m 0644 ${UNPACKDIR}/var-lib-bluetooth.mount ${D}${systemd_system_unitdir}/var-lib-bluetooth.mount
    install -m 0644 ${UNPACKDIR}/wendyos-bluetooth-state.service \
        ${D}${systemd_system_unitdir}/wendyos-bluetooth-state.service

    install -m 0644 ${UNPACKDIR}/var-lib-systemd-timesync.mount \
        ${D}${systemd_system_unitdir}/var-lib-systemd-timesync.mount
    install -m 0644 ${UNPACKDIR}/wendyos-timesync-state.service \
        ${D}${systemd_system_unitdir}/wendyos-timesync-state.service

    # Drop-ins rather than bbappends on bluez5 and systemd: the ordering
    # requirement comes from this recipe's mount units, so it belongs with them.
    install -d ${D}${systemd_system_unitdir}/bluetooth.service.d
    install -m 0644 ${UNPACKDIR}/bluetooth-persist-state.conf \
        ${D}${systemd_system_unitdir}/bluetooth.service.d/persist-state.conf

    install -d ${D}${systemd_system_unitdir}/systemd-timesyncd.service.d
    install -m 0644 ${UNPACKDIR}/timesyncd-persist-clock.conf \
        ${D}${systemd_system_unitdir}/systemd-timesyncd.service.d/persist-clock.conf
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/var-lib-wendy.mount \
    ${systemd_system_unitdir}/var-lib-bluetooth.mount \
    ${systemd_system_unitdir}/wendyos-bluetooth-state.service \
    ${systemd_system_unitdir}/bluetooth.service.d/persist-state.conf \
    ${systemd_system_unitdir}/var-lib-systemd-timesync.mount \
    ${systemd_system_unitdir}/wendyos-timesync-state.service \
    ${systemd_system_unitdir}/systemd-timesyncd.service.d/persist-clock.conf \
"

RDEPENDS:${PN} = "systemd"
