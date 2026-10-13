SUMMARY = "Systemd mount units for state that must survive an A/B OTA swap"
DESCRIPTION = "Bind mounts state that must outlive an A/B OTA swap from the /data \
partition instead of the small A/B rootfs: /var/lib/wendy for persistent app volumes \
(created under /var/lib/wendy/volumes by the agent), and /var/lib/bluetooth for BlueZ \
pairing state, which the device would otherwise forget on every update."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://var-lib-wendy.mount \
    file://var-lib-bluetooth.mount \
    file://wendyos-bluetooth-state.service \
    file://bluetooth-persist-state.conf \
"
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "var-lib-wendy.mount var-lib-bluetooth.mount wendyos-bluetooth-state.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-wendy.mount ${D}${systemd_system_unitdir}/var-lib-wendy.mount
    install -m 0644 ${UNPACKDIR}/var-lib-bluetooth.mount ${D}${systemd_system_unitdir}/var-lib-bluetooth.mount
    install -m 0644 ${UNPACKDIR}/wendyos-bluetooth-state.service \
        ${D}${systemd_system_unitdir}/wendyos-bluetooth-state.service

    # Drop-in rather than a bbappend on bluez5: the ordering requirement comes
    # from this recipe's mount unit, so it belongs with it.
    install -d ${D}${systemd_system_unitdir}/bluetooth.service.d
    install -m 0644 ${UNPACKDIR}/bluetooth-persist-state.conf \
        ${D}${systemd_system_unitdir}/bluetooth.service.d/persist-state.conf
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/var-lib-wendy.mount \
    ${systemd_system_unitdir}/var-lib-bluetooth.mount \
    ${systemd_system_unitdir}/wendyos-bluetooth-state.service \
    ${systemd_system_unitdir}/bluetooth.service.d/persist-state.conf \
"

RDEPENDS:${PN} = "systemd"
