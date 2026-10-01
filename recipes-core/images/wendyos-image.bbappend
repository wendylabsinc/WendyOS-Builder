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

# Replace placeholders in the tegraflash rootfs layouts so DTB_FILE, DATAFILE,
# and APPFILE become real filenames before make-jetson-disk-img.py reads them:
# external-flash.xml.in for NVMe machines, and flash.xml.in's sdcard device for
# the Nano SD machine. Uses the tegraflash_custom_post hook, which runs after
# XML creation but before archiving.

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

    # Replace placeholders in external-flash.xml.in (NVMe machines only).
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

    # Replace placeholders in flash.xml.in for the Nano SD rootfs-only image.
    # The SD machine has no external-flash.xml.in; make-jetson-disk-img.py reads
    # flash.xml.in's sdcard device directly, so its DTB_FILE/APPFILE tokens must
    # be resolved here — same rootfs-only shape as the NVMe external layout.
    # Anchored to the tag boundary (>...<) so BPFDTB_FILE and other boot-chain
    # tokens, resolved later by the recovery flow, are never touched. Scoped to
    # the SD machine so the AGX/NVMe flash.xml.in used for recovery keeps its raw
    # placeholders.
    if [ "${MACHINE}" = "jetson-orin-nano-devkit-wendyos" ] && [ -f "flash.xml.in" ]; then
        DTB_NAME="$(basename ${KERNEL_DEVICETREE})"
        sed -i \
            -e "s,>[[:space:]]*DTB_FILE[[:space:]]*<,> ${DTB_NAME} <," \
            -e "s,>[[:space:]]*DATAFILE[[:space:]]*<,> ${IMAGE_LINK_NAME}.dataimg <," \
            -e "s,>[[:space:]]*APPFILE_b[[:space:]]*<,> ${IMAGE_BASENAME}.${IMAGE_TEGRAFLASH_FS_TYPE} <," \
            -e "s,>[[:space:]]*APPFILE[[:space:]]*<,> ${IMAGE_BASENAME}.${IMAGE_TEGRAFLASH_FS_TYPE} <," \
            flash.xml.in
        bbnote "Replaced placeholders in flash.xml.in (Nano SD rootfs image)"
    fi
}

# Add fstab entry for config partition on Jetson (RPi5 has it in rpi-fstab)
add_config_fstab() {
    echo "LABEL=config  /config  vfat  defaults,nofail  0 0" >> ${IMAGE_ROOTFS}${sysconfdir}/fstab
    mkdir -p ${IMAGE_ROOTFS}/config
}
ROOTFS_POSTPROCESS_COMMAND:append:tegra = " add_config_fstab;"
