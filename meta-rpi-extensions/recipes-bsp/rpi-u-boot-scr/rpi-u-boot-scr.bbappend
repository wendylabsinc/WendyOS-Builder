# WendyOS A/B trial-boot script for the wendyos-update OTA stack.
#
# When WENDYOS_OTA = "wendy", replace the stock single-rootfs boot.scr with one
# that selects the A/B rootfs slot from the U-Boot env (wendyos_boot_slot) and
# implements trial boot via an in-script bootcount. Env lives in uboot.env on
# the FAT boot partition (stock meta-raspberrypi U-Boot — no patches). For any
# other WENDYOS_OTA value the original do_compile behaviour is preserved
# verbatim, so Mender/non-OTA RPi builds are unaffected.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "${@' file://boot-ab.cmd.in' if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"

# Slot -> rootfs partition number. MUST match wic/rpi-wendy-ab*.wks
# (p3 = rootfsA = slot 0, p4 = rootfsB = slot 1).
WENDYOS_ROOTFS_PART_A ?= "3"
WENDYOS_ROOTFS_PART_B ?= "4"

# Trial-boot retry budget: how many times the new slot may boot without being
# committed before U-Boot falls back. 1 = one attempt (matches Mender's default).
WENDYOS_BOOTLIMIT ?= "1"

# root= device base and the U-Boot load interface/device. Defaults target the
# SD card (mmcblk0 / mmc 0); the NVMe machine overrides them below and adds the
# `nvme scan` that U-Boot needs before NVMe block devices appear.
WENDYOS_ROOT_DEV_BASE ?= "/dev/mmcblk0p"
WENDYOS_UBOOT_IF      ?= "mmc"
WENDYOS_UBOOT_DEV     ?= "0"
WENDYOS_UBOOT_PRECMD  ?= ""

WENDYOS_ROOT_DEV_BASE:raspberrypi5-nvme = "/dev/nvme0n1p"
WENDYOS_UBOOT_IF:raspberrypi5-nvme      = "nvme"
WENDYOS_UBOOT_PRECMD:raspberrypi5-nvme  = "nvme scan"

# Re-run if any of the templated knobs change.
do_compile[vardeps] += "WENDYOS_OTA WENDYOS_ROOTFS_PART_A WENDYOS_ROOTFS_PART_B \
                        WENDYOS_BOOTLIMIT WENDYOS_ROOT_DEV_BASE WENDYOS_UBOOT_IF \
                        WENDYOS_UBOOT_DEV WENDYOS_UBOOT_PRECMD"

do_compile() {
    if [ "${WENDYOS_OTA}" = "wendy" ]; then
        # '#' delimiter for the device-base sub (it contains '/').
        sed -e 's/@@KERNEL_IMAGETYPE@@/${KERNEL_IMAGETYPE}/' \
            -e 's/@@KERNEL_BOOTCMD@@/${KERNEL_BOOTCMD}/' \
            -e 's/@@WENDYOS_UBOOT_IF@@/${WENDYOS_UBOOT_IF}/' \
            -e 's/@@WENDYOS_UBOOT_DEV@@/${WENDYOS_UBOOT_DEV}/' \
            -e 's/@@WENDYOS_UBOOT_PRECMD@@/${WENDYOS_UBOOT_PRECMD}/' \
            -e 's/@@WENDYOS_ROOTFS_PART_A@@/${WENDYOS_ROOTFS_PART_A}/' \
            -e 's/@@WENDYOS_ROOTFS_PART_B@@/${WENDYOS_ROOTFS_PART_B}/' \
            -e 's/@@WENDYOS_BOOTLIMIT@@/${WENDYOS_BOOTLIMIT}/' \
            -e 's#@@WENDYOS_ROOT_DEV_BASE@@#${WENDYOS_ROOT_DEV_BASE}#' \
            "${WORKDIR}/boot-ab.cmd.in" > "${WORKDIR}/boot.cmd"
    else
        sed -e 's/@@KERNEL_IMAGETYPE@@/${KERNEL_IMAGETYPE}/' \
            -e 's/@@KERNEL_BOOTCMD@@/${KERNEL_BOOTCMD}/' \
            -e 's/@@BOOT_MEDIA@@/${BOOT_MEDIA}/' \
            "${WORKDIR}/boot.cmd.in" > "${WORKDIR}/boot.cmd"
    fi
    mkimage -A ${UBOOT_ARCH} -T script -C none -n "Boot script" -d "${WORKDIR}/boot.cmd" boot.scr
}
