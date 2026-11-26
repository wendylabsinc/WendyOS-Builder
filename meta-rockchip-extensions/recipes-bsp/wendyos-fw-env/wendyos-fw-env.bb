SUMMARY = "U-Boot fw_env.config for the WendyOS Rockchip A/B OTA stack"
DESCRIPTION = "Installs /etc/fw_env.config so libubootenv (fw_printenv/fw_setenv), \
used by the wendyos-update ubootenv connector to flip A/B slots, finds uboot.env \
on the boot partition mounted at /boot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "rockchip-wendyos"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# The size the boot script saves uboot.env at; any other size reads as corrupt.
do_install() {
    install -d ${D}${sysconfdir}
    printf '/boot/uboot.env 0x0000 %s\n' "${WENDYOS_UBOOT_ENV_SIZE}" > ${D}${sysconfdir}/fw_env.config
}

FILES:${PN} = "${sysconfdir}/fw_env.config"

# fw_printenv/fw_setenv at runtime.
RDEPENDS:${PN} = "libubootenv-bin"
