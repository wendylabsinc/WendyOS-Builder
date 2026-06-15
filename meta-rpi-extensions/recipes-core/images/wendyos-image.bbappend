# RPi: place the "config" partition before /data, and fix up the resulting fstab.
#
# Pull the WKS-reorder class in via IMAGE_CLASSES *from this bbappend*. Mender's
# mender-setup.bbclass does `IMAGE_CLASSES += "mender-part-images ..."` during the
# recipe's inherit; appending our class to IMAGE_CLASSES in a bbappend (parsed
# after the recipe) places it AFTER mender-part-images, and poky's
# `inherit_defer ${IMGCLASSES}` (end of parse) then inherits them in order -- so
# our mender_part_image override is the last definition and wins. (A plain
# `inherit` here loses: it runs before the deferred IMGCLASSES inherit.)
# meta-rpi-extensions is only layered for RPi, so this stays RPi-only; on an image
# without extra partitions the reorder is a no-op.
IMAGE_CLASSES:append = " mender-config-before-data"
#
# mender-config-before-data.bbclass places the FAT "config" partition BEFORE
# /data, so the on-disk layout is: boot(p1) rootfsA(p2) rootfsB(p3) extended(p4)
# config(p5) data(p6). But Mender's mender_update_fstab_file emits the /config
# line number-based assuming config sits AFTER /data (offset = data+1), which now
# points at /data. Rewrite that line to config's real device (the first logical,
# ${MENDER_STORAGE_DEVICE_BASE}5). This bbappend is parsed after the recipe's
# Mender inherits, so this ROOTFS_POSTPROCESS runs AFTER mender_update_fstab_file.
fix_config_fstab_rpi() {
    # Drop whatever /config line Mender wrote, then add the correct one.
    sed -i -E '/[[:space:]]+\/config[[:space:]]+/d' ${IMAGE_ROOTFS}${sysconfdir}/fstab
    printf "%-20s %-20s %-10s %-21s %-2s %s\n" \
        "${MENDER_STORAGE_DEVICE_BASE}5" /config vfat defaults,nofail 0 0 \
        >> ${IMAGE_ROOTFS}${sysconfdir}/fstab
}
ROOTFS_POSTPROCESS_COMMAND:append:rpi = " fix_config_fstab_rpi;"
