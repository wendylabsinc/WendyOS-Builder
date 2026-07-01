SUMMARY = "U-Boot fw_env.config for the WendyOS RPi A/B OTA stack"
DESCRIPTION = "Installs /etc/fw_env.config so libubootenv (fw_printenv/fw_setenv) \
— used by the wendyos-update ubootenv connector to flip A/B slots — finds the \
U-Boot environment (uboot.env on the FAT boot partition, mounted at \
/boot/firmware). Pulls in libubootenv as the fw-utils provider."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://fw_env.config"
S = "${UNPACKDIR}"

# Only meaningful for the wendyos-update OTA stack on RPi.
COMPATIBLE_MACHINE = "rpi"

do_install() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${UNPACKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}

FILES:${PN} = "${sysconfdir}/fw_env.config"

# fw_printenv/fw_setenv at runtime.
RDEPENDS:${PN} = "libubootenv-bin"

