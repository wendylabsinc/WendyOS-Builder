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

# Follow the boot device instead of the fixed one above: load from whichever
# device standard boot found boot.scr on (devtype/devnum), keep the A/B env in
# uboot.env on that device (not U-Boot's compiled-in mmc 0:1), and pass
# root=PARTUUID=. The template's @@BOOTDEV@@ lines are kept and its @@FIXED@@
# lines dropped; with "0" the reverse, so the output is unchanged.
#
# RPi4: one image boots from SD or a USB disk (incl. USB-NVMe enclosures); its
# stock U-Boot already runs "pci enum; usb start" and scans mmc then usb.
# RPi4 only for now; RPi3/RPi5 keep their bench-validated fixed scripts.
WENDYOS_UBOOT_FOLLOW_BOOTDEV ?= "0"
WENDYOS_UBOOT_FOLLOW_BOOTDEV:raspberrypi4-64 = "1"

# Upper bound for U-Boot's DTB placement (see boot-ab.cmd.in). Empty drops the
# setenv line, leaving fdt_high unset. Pi 4: 0x3e000000 is above the 768 MB CMA
# window on every RAM size, because the first bank is the low 1 GB minus the
# firmware's GPU memory on all of them; U-Boot never places the DTB above free
# RAM, so the bound only has to be high enough. Pi 3/5 keep their
# bench-validated layout.
WENDYOS_UBOOT_FDT_HIGH ?= ""
WENDYOS_UBOOT_FDT_HIGH:raspberrypi4-64 = "0x3e000000"

# Must equal U-Boot's CONFIG_ENV_SIZE and the size in fw_env.config.
WENDYOS_UBOOT_ENV_SIZE ?= "0x4000"

# RPi3 (BCM2837) boots MBR only, so its A/B wks (rpi-wendy-ab-mbr.wks) puts the
# two rootfs slots on PRIMARY partitions p2/p3 (boot=p1; config/data are logical
# p5/p6 inside the extended partition) — NOT the GPT p3/p4 the defaults assume.
# SD card, so the mmc / mmcblk0 device defaults still hold.
WENDYOS_ROOTFS_PART_A:raspberrypi3-64 = "2"
WENDYOS_ROOTFS_PART_B:raspberrypi3-64 = "3"

# Re-run if any of the templated knobs change.
do_compile[vardeps] += "WENDYOS_OTA WENDYOS_ROOTFS_PART_A WENDYOS_ROOTFS_PART_B \
                        WENDYOS_BOOTLIMIT WENDYOS_ROOT_DEV_BASE WENDYOS_UBOOT_IF \
                        WENDYOS_UBOOT_DEV WENDYOS_UBOOT_PRECMD \
                        WENDYOS_UBOOT_FOLLOW_BOOTDEV WENDYOS_UBOOT_ENV_SIZE \
                        WENDYOS_UBOOT_FDT_HIGH"

do_compile() {
    if [ "${WENDYOS_OTA}" = "wendy" ]; then
        if [ "${WENDYOS_UBOOT_FOLLOW_BOOTDEV}" = "1" ]; then
            keep=BOOTDEV drop=FIXED
        else
            keep=FIXED drop=BOOTDEV
        fi
        if [ -n "${WENDYOS_UBOOT_FDT_HIGH}" ]; then
            fdt_high='s/@@WENDYOS_UBOOT_FDT_HIGH@@/${WENDYOS_UBOOT_FDT_HIGH}/'
        else
            fdt_high='/@@WENDYOS_UBOOT_FDT_HIGH@@/d'
        fi
        # '#' delimiter for the device-base sub (it contains '/').
        sed -e "/^@@$drop@@/d" \
            -e "s/^@@$keep@@//" \
            -e 's/@@KERNEL_IMAGETYPE@@/${KERNEL_IMAGETYPE}/' \
            -e 's/@@KERNEL_BOOTCMD@@/${KERNEL_BOOTCMD}/' \
            -e 's/@@WENDYOS_UBOOT_IF@@/${WENDYOS_UBOOT_IF}/' \
            -e 's/@@WENDYOS_UBOOT_DEV@@/${WENDYOS_UBOOT_DEV}/' \
            -e 's/@@WENDYOS_UBOOT_PRECMD@@/${WENDYOS_UBOOT_PRECMD}/' \
            -e 's/@@WENDYOS_ROOTFS_PART_A@@/${WENDYOS_ROOTFS_PART_A}/' \
            -e 's/@@WENDYOS_ROOTFS_PART_B@@/${WENDYOS_ROOTFS_PART_B}/' \
            -e 's/@@WENDYOS_BOOTLIMIT@@/${WENDYOS_BOOTLIMIT}/' \
            -e 's/@@WENDYOS_UBOOT_ENV_SIZE@@/${WENDYOS_UBOOT_ENV_SIZE}/g' \
            -e "$fdt_high" \
            -e 's#@@WENDYOS_ROOT_DEV_BASE@@#${WENDYOS_ROOT_DEV_BASE}#' \
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

