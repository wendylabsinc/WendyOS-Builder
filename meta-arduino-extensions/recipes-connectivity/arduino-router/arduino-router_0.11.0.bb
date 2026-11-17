SUMMARY = "Arduino's MessagePack-RPC router between the UNO Q MCU and Linux apps"
DESCRIPTION = "Bridges the sketch on the STM32, over /dev/ttyHS1, and Linux \
clients on a unix socket. Apps reach it through the arduino-bridge entitlement."
HOMEPAGE = "https://github.com/arduino/arduino-router"
LICENSE = "GPL-3.0-or-later"
LIC_FILES_CHKSUM = "file://src/${GO_IMPORT}/LICENSE.txt;md5=1ebbd3e34237af26da5dc08a4e440464"

require ${BPN}-licenses.inc

SRC_URI = "git://github.com/arduino/arduino-router.git;protocol=https;nobranch=1;destsuffix=${GO_SRCURI_DESTSUFFIX} \
           file://wendyos-arduino-router.service \
           file://arduino-router.tmpfiles \
           "
# v0.11.0
SRCREV = "cb7b2cecee1c04e0ba0a7fb48da63a8a7a1dba71"

require ${BPN}-go-mods.inc

GO_IMPORT = "github.com/arduino/arduino-router"
GO_INSTALL = "${GO_IMPORT}"
GO_LINKSHARED = ""
GO_EXTRA_LDFLAGS = "-X main.Version=${PV}"

inherit go-mod go-mod-update-modules systemd useradd

COMPATIBLE_MACHINE = "arduino-uno-q-wendyos"

USERADD_PACKAGES = "${PN}"
# A fixed GID: containers keep the GID they were created with, and a dynamic
# one moves whenever another image adds a system group.
GROUPADD_PARAM:${PN} = "-r -g 880 arduino-router"

SYSTEMD_SERVICE:${PN} = "wendyos-arduino-router.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = "wendyos-mcu"

do_install() {
    install -d ${D}${bindir} ${D}${systemd_system_unitdir} ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0755 ${B}/${GO_BUILD_BINDIR}/arduino-router ${D}${bindir}/
    install -m 0644 ${UNPACKDIR}/wendyos-arduino-router.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/arduino-router.tmpfiles ${D}${nonarch_libdir}/tmpfiles.d/arduino-router.conf
}

FILES:${PN} += "${nonarch_libdir}/tmpfiles.d"
