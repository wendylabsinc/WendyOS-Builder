# WendyOS A/B trial-boot script for the wendyos-update OTA stack.
#
# When WENDYOS_OTA = "wendy", replace the stock single-rootfs boot.scr with one
# that selects the A/B rootfs slot from the U-Boot env (wendyos_boot_slot) and
# implements trial boot via an in-script bootcount. Env lives in uboot.env on
# the FAT boot partition (stock meta-raspberrypi U-Boot — no patches). For any
# other WENDYOS_OTA value the original do_compile behaviour is preserved
# verbatim, so non-OTA RPi builds are unaffected.
#
# The slot-selection head is shared with the other U-Boot boards
# (recipes-bsp/wendyos-boot-ab); files/boot-ab-rpi.cmd.in is the Pi's tail.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

require recipes-bsp/wendyos-boot-ab/wendyos-boot-ab.inc

SRC_URI += "${@' file://boot-ab-rpi.cmd.in' if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"

# Upper bound for U-Boot's DTB placement (see boot-ab-rpi.cmd.in); empty unsets
# it. Pi 4: above the top of free low RAM on every model, so U-Boot puts the DTB
# as high as it can, clear of the CMA window.
WENDYOS_UBOOT_FDT_HIGH ?= ""
WENDYOS_UBOOT_FDT_HIGH:raspberrypi4-64 = "0x3e000000"

# RPi3 (BCM2837) boots MBR only, so its A/B wks (rpi-wendy-ab-mbr.wks) puts the
# two rootfs slots on PRIMARY partitions p2/p3 (boot=p1; config/data are logical
# p5/p6 inside the extended partition) — NOT the GPT p3/p4 the defaults assume.
WENDYOS_ROOTFS_PART_A:raspberrypi3-64 = "2"
WENDYOS_ROOTFS_PART_B:raspberrypi3-64 = "3"

# Re-run if any of the templated knobs change.
do_compile[vardeps] += "WENDYOS_OTA WENDYOS_ROOTFS_PART_A WENDYOS_ROOTFS_PART_B \
                        WENDYOS_BOOTLIMIT WENDYOS_UBOOT_ENV_SIZE \
                        WENDYOS_UBOOT_FDT_HIGH"

do_compile() {
    if [ "${WENDYOS_OTA}" = "wendy" ]; then
        wendyos_render_boot_ab "${UNPACKDIR}/boot-ab-rpi.cmd.in" "${WORKDIR}/boot.cmd" \
            KERNEL_IMAGETYPE=${KERNEL_IMAGETYPE} \
            KERNEL_BOOTCMD=${KERNEL_BOOTCMD} \
            WENDYOS_UBOOT_FDT_HIGH=${WENDYOS_UBOOT_FDT_HIGH}
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
