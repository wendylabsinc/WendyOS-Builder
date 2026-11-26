SUMMARY = "WendyOS A/B U-Boot boot script for Rockchip boards"
DESCRIPTION = "The boot script on the boot partition: picks the rootfs slot from \
uboot.env (wendyos-update ubootenv connector), counts trial boots, and boots \
the kernel and DTB from the selected slot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "rockchip-wendyos"
PACKAGE_ARCH = "${MACHINE_ARCH}"

INHIBIT_DEFAULT_DEPS = "1"
DEPENDS = "u-boot-mkimage-native"

inherit deploy nopackages

require recipes-bsp/wendyos-boot-ab/wendyos-boot-ab.inc

SRC_URI += "file://boot-ab-rockchip.cmd.in"
S = "${UNPACKDIR}"

# The microSD is mmc 1 (DT alias). '=', not '?=': the shared include already set
# its default.
WENDYOS_SD_MMC_DEV = "1"

# Release images: console on the VT only. Debug images (WENDYOS_DEBUG_UART=1)
# also get the debug UART, last, so /dev/console is the serial port.
WENDYOS_ROCKCHIP_DEBUG_CONSOLE ?= "console=${RK_CONSOLE_DEVICE},${RK_CONSOLE_BAUD}n8"
WENDYOS_ROCKCHIP_CONSOLE_ARGS = "console=tty0${@' ' + d.getVar('WENDYOS_ROCKCHIP_DEBUG_CONSOLE') if d.getVar('WENDYOS_DEBUG_UART') == '1' else ''}"

do_compile() {
    wendyos_render_boot_ab "${UNPACKDIR}/boot-ab-rockchip.cmd.in" "${B}/boot.cmd" \
        KERNEL_IMAGETYPE=${KERNEL_IMAGETYPE} \
        WENDYOS_ROCKCHIP_DTB=${WENDYOS_ROCKCHIP_DTB} \
        "WENDYOS_CONSOLE_ARGS=${WENDYOS_ROCKCHIP_CONSOLE_ARGS}"
    mkimage -A ${@oe.kernel.map_uboot_arch(d)} -T script -C none -n "WendyOS boot script" \
        -d "${B}/boot.cmd" "${B}/boot.scr"
}

do_deploy() {
    install -m 0644 ${B}/boot.scr ${DEPLOYDIR}/${WENDYOS_ROCKCHIP_BOOT_SCRIPT}
}
addtask deploy after do_compile before do_build
