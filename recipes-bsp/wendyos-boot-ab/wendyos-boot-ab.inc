# The WendyOS A/B U-Boot boot script shared by the U-Boot boards: one
# slot-selection head plus each family's boot tail.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://boot-ab-slot.cmd.in \
    file://boot-ab-render.sh \
    "

# Slot -> rootfs partition; must match the board's A/B wks.
WENDYOS_ROOTFS_PART_A ?= "3"
WENDYOS_ROOTFS_PART_B ?= "4"

# Uncommitted boots a trial slot gets before U-Boot falls back.
WENDYOS_BOOTLIMIT ?= "1"

# setexpr writes hex and test -gt reads decimal; they agree only up to 9.
python () {
    limit = d.getVar('WENDYOS_BOOTLIMIT')
    if not limit.isdigit() or not 1 <= int(limit) <= 8:
        bb.fatal('WENDYOS_BOOTLIMIT must be 1..8, got %s' % limit)
}

# Must equal the size in fw_env.config (and U-Boot's CONFIG_ENV_SIZE where
# U-Boot itself loads uboot.env).
WENDYOS_UBOOT_ENV_SIZE ?= "0x4000"

# U-Boot mmc number of the SD card, for a hand-sourced script.
WENDYOS_SD_MMC_DEV ?= "0"

# Usage: wendyos_render_boot_ab TAIL OUT [NAME=VALUE...] (the tail's placeholders)
wendyos_render_boot_ab() {
    tail_template="$1"
    output="$2"
    shift 2
    sh ${UNPACKDIR}/boot-ab-render.sh ${UNPACKDIR}/boot-ab-slot.cmd.in "$tail_template" "$output" \
        WENDYOS_ROOTFS_PART_A=${WENDYOS_ROOTFS_PART_A} \
        WENDYOS_ROOTFS_PART_B=${WENDYOS_ROOTFS_PART_B} \
        WENDYOS_BOOTLIMIT=${WENDYOS_BOOTLIMIT} \
        WENDYOS_UBOOT_ENV_SIZE=${WENDYOS_UBOOT_ENV_SIZE} \
        WENDYOS_SD_MMC_DEV=${WENDYOS_SD_MMC_DEV} \
        "$@"
}
