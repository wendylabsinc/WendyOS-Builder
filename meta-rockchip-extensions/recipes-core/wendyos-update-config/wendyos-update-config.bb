SUMMARY = "wendyos-update connector config for Rockchip boards (ubootenv)"
DESCRIPTION = "Installs /etc/wendyos-update/config.json pinning the wendyos-update \
OTA client to the ubootenv connector."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://config.json"
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "rockchip-wendyos"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${sysconfdir}/wendyos-update
    install -m 0644 ${UNPACKDIR}/config.json ${D}${sysconfdir}/wendyos-update/config.json
}

# The config dir is also created by the wendyos-update recipe (the <phase>.d
# hook dirs); allow both to ship it.
FILES:${PN} = "${sysconfdir}/wendyos-update/config.json"
