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

# On T264 (Thor) udev does not reliably emit block-device activation events,
# so any mount unit whose What= uses /dev/disk/by-*/ will wait 90 s for a
# device unit that never becomes active.
#
# boot-efi.mount: comes from upstream meta-tegra (fstab entry for the ESP).
# Thor runs WENDYOS_OTA="wendy" — Mender is absent, so the ESP does not need
# a persistent runtime mount. Mask it so it is never started.
#
# fstab nofail sweep: for any remaining by-* entries that upstream adds (e.g.
# the ESP entry that generates boot-efi.mount), add nofail + a 5 s device
# timeout so stale device units don't add 90 s each to boot time.
mask_boot_efi_mount() {
    install -d ${IMAGE_ROOTFS}${systemd_system_unitdir}
    ln -sf /dev/null ${IMAGE_ROOTFS}${systemd_system_unitdir}/boot-efi.mount
}
ROOTFS_POSTPROCESS_COMMAND:append:tegra264 = " mask_boot_efi_mount;"

fix_tegra_fstab_device_timeouts() {
    local fstab="${IMAGE_ROOTFS}${sysconfdir}/fstab"
    [ -f "${fstab}" ] || return 0
    # For every line whose device field starts with /dev/disk/by-, append
    # nofail and x-systemd.device-timeout=5 to the options column (4th field)
    # unless they are already present.
    awk '
        /^[[:space:]]*#/ { print; next }
        $1 ~ /^\/dev\/disk\/by-/ && $4 !~ /device-timeout/ {
            sub(/[[:space:]]+[0-9]+[[:space:]]+[0-9]+$/, "")
            $4 = $4 ",nofail,x-systemd.device-timeout=5"
            print $0 "\t0 0"
            next
        }
        { print }
    ' "${fstab}" > "${fstab}.tmp" && mv "${fstab}.tmp" "${fstab}"
}
ROOTFS_POSTPROCESS_COMMAND:append:tegra264 = " fix_tegra_fstab_device_timeouts;"
