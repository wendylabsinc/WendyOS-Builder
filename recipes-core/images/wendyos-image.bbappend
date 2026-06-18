# Replace placeholders in external-flash.xml.in for NVMe flash images
# This ensures DTB_FILE, DATAFILE, and APPFILE are replaced with actual filenames
# Uses the tegraflash_custom_post hook which runs after XML creation but before archiving

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
    # "ext4.simg" — sparse). Hardcoding ".ext4" here was a latent bug:
    # scarthgap's flash.sh auto-handled the mismatch, but r38.4.x's new
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

# The /config mount point and mount service are provided by the
# wendyos-config-mount package (see recipes-core/wendyos-config-mount/).
# That service uses blkid instead of a fstab LABEL= entry so it works on
# platforms where udev does not emit by-label symlinks (e.g. Jetson Thor).
