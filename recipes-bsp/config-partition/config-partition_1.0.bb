SUMMARY = "FAT32 config partition image for Tegra flash"
DESCRIPTION = "Creates a FAT32 partition image deployed to DEPLOY_DIR_IMAGE \
for inclusion in the Tegra tegraflash package. RPi does not use this recipe — \
its config partition is created by the rpi-wendy-ab*.wks wic layout, placed \
before /data, and persists."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit deploy nopackages

DEPENDS = "dosfstools-native mtools-native"

# Only Tegra machines need the deployed image (RPi5 uses WIC)
COMPATIBLE_MACHINE = "(tegra)"

do_compile() {
    dd if=/dev/zero of=${B}/config-partition.fat32.img \
       bs=1M count=${WENDYOS_CONFIG_PART_SIZE_MB}
    mkfs.fat -F 32 -n "config" ${B}/config-partition.fat32.img
    # Protect cards written by any flashing tool, not only Wendy CLI on macOS.
    touch "${B}/.metadata_never_index"
    mcopy -o -i "${B}/config-partition.fat32.img" "${B}/.metadata_never_index" ::/.metadata_never_index
}

do_deploy() {
    install -m 0644 ${B}/config-partition.fat32.img ${DEPLOYDIR}/config-partition.fat32.img
}

addtask deploy after do_compile before do_build
