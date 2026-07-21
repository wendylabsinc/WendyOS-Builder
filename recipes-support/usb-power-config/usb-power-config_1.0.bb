SUMMARY = "USB power management policy for robotics peripherals"
DESCRIPTION = "Disables USB autosuspend via udev so low-traffic peripherals \
    (USB-CAN adapters, sensors) stay on the bus instead of being suspended \
    and dropping off after the 2s kernel default timeout (WDY-1924)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-wendyos-usb-no-autosuspend.rules"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/99-wendyos-usb-no-autosuspend.rules ${D}${sysconfdir}/udev/rules.d/
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/99-wendyos-usb-no-autosuspend.rules"

RDEPENDS:${PN} = "udev"
