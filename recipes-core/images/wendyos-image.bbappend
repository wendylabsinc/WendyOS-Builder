# Protect every FAT volume in WIC disk images, including boot and config,
# before image conversion produces compressed files or block maps.
# Image recipes do not execute do_fetch/do_unpack; use the layer file directly
# and include its contents in the task signature.
WENDYOS_FAT_MARKER_SCRIPT := "${THISDIR}/files/mark-fat-volumes.py"
do_image_wic[file-checksums] += "${WENDYOS_FAT_MARKER_SCRIPT}:True"
do_image_wic[depends] += "util-linux-native:do_populate_sysroot mtools-native:do_populate_sysroot python3-native:do_populate_sysroot"
IMAGE_CMD:wic:append() {

    "${STAGING_BINDIR_NATIVE}/python3-native/python3" "${WENDYOS_FAT_MARKER_SCRIPT}" "${IMGDEPLOYDIR}/${IMAGE_NAME}.wic"
}

# Ensure config-partition FAT32 image is built before the tegraflash package
EXTRA_IMAGEDEPENDS:append:tegra = " config-partition"

tegraflash_custom_post:append() {
    # Copy config partition FAT32 image into the tegraflash package (all Tegra machines)
    if [ -f "${DEPLOY_DIR_IMAGE}/config-partition.fat32.img" ]; then
        cp "${DEPLOY_DIR_IMAGE}/config-partition.fat32.img" ./config-partition.fat32.img
        bbnote "Copied config-partition.fat32.img into tegraflash package"
    else
        bbfatal "config-partition.fat32.img not found in DEPLOY_DIR_IMAGE"
    fi

    # Replace placeholders in external-flash.xml.in, which every Orin install target is made from.
    # APPFILE/APPFILE_b must match the actual rootfs filename in the
    # bundle, which is governed by IMAGE_TEGRAFLASH_FS_TYPE (default
    # "ext4.simg" — sparse). Hardcoding ".ext4" here was a latent bug: the
    # older flash.sh auto-handled the mismatch, but r38.4.x's new
    # unified-flash flow (create_l4t_bsp_images.py) does a literal
    # shutil.move on the XML-referenced filename and fails ENOENT.
    if [ -f "external-flash.xml.in" ]; then
        DTB_NAME="$(basename ${KERNEL_DEVICETREE})"
        sed -i \
            -e "s,DTB_FILE,${DTB_NAME}," \
            -e "s,DATAFILE,${IMAGE_LINK_NAME}.dataimg," \
            -e "s,APPFILE_b,${IMAGE_BASENAME}.${IMAGE_TEGRAFLASH_FS_TYPE}," \
            -e "s,APPFILE,${IMAGE_BASENAME}.${IMAGE_TEGRAFLASH_FS_TYPE}," \
            external-flash.xml.in
        bbnote "Replaced placeholders in external-flash.xml.in"
    fi
}

# Add fstab entry for config partition on Jetson (RPi5 has it in rpi-fstab)
# Type auto, not vfat: /config is FAT today and is converted to ext4 in place later.
# By the /dev/wendyos/config link, not LABEL=config: an AGX Orin moved from eMMC
# to NVMe has a config partition on both disks, and the link names only the one
# on the disk / is mounted from (99-wendyos-config.rules, data-device recipe).
add_config_fstab() {
    echo "/dev/wendyos/config  /config  auto  defaults,nofail  0 0" >> ${IMAGE_ROOTFS}${sysconfdir}/fstab
    mkdir -p ${IMAGE_ROOTFS}/config
}
ROOTFS_POSTPROCESS_COMMAND:append:tegra = " add_config_fstab;"

# A minimal UEFI drives only the TNSPEC_BOOTDEV disk class, and the Orin images boot from SD, eMMC or NVMe.
python () {
    if 'tegra234' in d.getVar('MACHINEOVERRIDES').split(':') and bb.utils.to_boolean(d.getVar('TEGRA_MINIMAL_BOOT')):
        bb.fatal('TEGRA_MINIMAL_BOOT must be "0" on Orin: a minimal UEFI cannot boot the SD card or eMMC.')
}
