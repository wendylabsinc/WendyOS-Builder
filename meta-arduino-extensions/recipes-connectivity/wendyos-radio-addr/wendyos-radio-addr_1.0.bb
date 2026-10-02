SUMMARY = "Factory Wi-Fi and Bluetooth addresses for the Arduino UNO Q"
DESCRIPTION = "The board keeps its radio addresses in the eMMC boot area. \
Arduino's U-Boot writes them into its devicetree, but GRUB boots the kernel \
with the slot's own, so without this the Wi-Fi MAC changes every boot and \
Bluetooth stays unconfigured with the chip's default address."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://wendyos-radio-addr.sh file://70-wendyos-radio-addr.rules \
           file://wendyos-bt-addr.service"
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "arduino-uno-q-wendyos"

inherit systemd
SYSTEMD_SERVICE:${PN} = "wendyos-bt-addr.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# btmgmt ships only in bluez5's noinst-tools package.
RDEPENDS:${PN} = "bluez5-noinst-tools coreutils iproute2-ip"

do_install() {
    install -d ${D}${bindir} ${D}${nonarch_base_libdir}/udev/rules.d ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/wendyos-radio-addr.sh ${D}${bindir}/
    install -m 0644 ${UNPACKDIR}/70-wendyos-radio-addr.rules ${D}${nonarch_base_libdir}/udev/rules.d/
    install -m 0644 ${UNPACKDIR}/wendyos-bt-addr.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${nonarch_base_libdir}/udev/rules.d"
