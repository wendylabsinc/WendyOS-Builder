# WendyOS A/B trial-boot script for the wendyos-update OTA stack.
#
# When WENDYOS_OTA = "wendy", replace the stock single-rootfs boot.scr with one
# that selects the A/B rootfs slot from the U-Boot env (wendyos_boot_slot) and
# implements trial boot via an in-script bootcount. Env lives in uboot.env on
# the FAT boot partition (stock meta-raspberrypi U-Boot — no patches). For any
# other WENDYOS_OTA value the original do_compile behaviour is preserved
# verbatim, so non-OTA RPi builds are unaffected.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "${@' file://boot-ab.cmd.in' if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"

# Slot -> rootfs partition number. MUST match files/wic/rpi-wendy-ab*.wks
# (p3 = rootfsA = slot 0, p4 = rootfsB = slot 1).
WENDYOS_ROOTFS_PART_A ?= "3"
WENDYOS_ROOTFS_PART_B ?= "4"

# Trial-boot retry budget: how many times the new slot may boot without being
# committed before U-Boot falls back. 1 = one attempt.
WENDYOS_BOOTLIMIT ?= "1"

# Must equal U-Boot's CONFIG_ENV_SIZE and the size in fw_env.config.
WENDYOS_UBOOT_ENV_SIZE ?= "0x4000"

# RPi3 (BCM2837) boots MBR only, so its A/B wks (rpi-wendy-ab-mbr.wks) puts the
# two rootfs slots on PRIMARY partitions p2/p3 (boot=p1; config/data are logical
# p5/p6 inside the extended partition) — NOT the GPT p3/p4 the defaults assume.
WENDYOS_ROOTFS_PART_A:raspberrypi3-64 = "2"
WENDYOS_ROOTFS_PART_B:raspberrypi3-64 = "3"

# Re-run if any of the templated knobs change.
do_compile[vardeps] += "WENDYOS_OTA WENDYOS_ROOTFS_PART_A WENDYOS_ROOTFS_PART_B \
                        WENDYOS_BOOTLIMIT WENDYOS_UBOOT_ENV_SIZE"

do_compile() {
    if [ "${WENDYOS_OTA}" = "wendy" ]; then
        sed -e 's/@@KERNEL_IMAGETYPE@@/${KERNEL_IMAGETYPE}/' \
            -e 's/@@KERNEL_BOOTCMD@@/${KERNEL_BOOTCMD}/' \
            -e 's/@@WENDYOS_ROOTFS_PART_A@@/${WENDYOS_ROOTFS_PART_A}/' \
            -e 's/@@WENDYOS_ROOTFS_PART_B@@/${WENDYOS_ROOTFS_PART_B}/' \
            -e 's/@@WENDYOS_BOOTLIMIT@@/${WENDYOS_BOOTLIMIT}/' \
            -e 's/@@WENDYOS_UBOOT_ENV_SIZE@@/${WENDYOS_UBOOT_ENV_SIZE}/g' \
            "${UNPACKDIR}/boot-ab.cmd.in" > "${WORKDIR}/boot.cmd"
    else
        sed -e 's/@@KERNEL_IMAGETYPE@@/${KERNEL_IMAGETYPE}/' \
            -e 's/@@KERNEL_BOOTCMD@@/${KERNEL_BOOTCMD}/' \
            -e 's/@@BOOT_MEDIA@@/${BOOT_MEDIA}/' \
            "${UNPACKDIR}/boot.cmd.in" > "${WORKDIR}/boot.cmd"
    fi
    # oe-core dropped the global UBOOT_ARCH from kernel-arch.bbclass; the mapping
    # now lives in oe/kernel.py and callers invoke it directly (see u-boot.inc
    # and kernel-uimage.bbclass). With the old form this expanded to nothing,
    # mkimage took "-T" as the value of "-A", and the build failed with
    # "Invalid architecture". meta-raspberrypi made the same change upstream in
    # a0ebcf56; we carry it here too because this do_compile replaces the
    # recipe's, so the upstream fix alone would never run for us.
    mkimage -A ${@oe.kernel.map_uboot_arch(d)} -T script -C none -n "Boot script" -d "${WORKDIR}/boot.cmd" boot.scr
}

