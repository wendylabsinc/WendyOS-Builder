# An AGX Orin can retain the vendor eMMC layout while running WendyOS from
# NVMe. Both disks have an "esp" partition, so the upstream global PARTLABEL
# mount can stage a capsule on the wrong disk. Resolve the ESP beside the
# running rootfs on every boot, including after a device-name change.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://wendyos-boot-efi-generator.sh"

do_install:append() {
    # Do not leave the ambiguous upstream mount available as a fallback when
    # the generator cannot establish an unambiguous root-disk ESP.
    rm -f ${D}${systemd_system_unitdir}/${ESPMOUNTUNIT}
    install -d ${D}${systemd_unitdir}/system-generators
    sed -e 's,@ESPMOUNT@,${ESPMOUNT},g' \
        -e 's,@ESPMOUNTUNIT@,${ESPMOUNTUNIT},g' \
        ${UNPACKDIR}/wendyos-boot-efi-generator.sh \
        > ${D}${systemd_unitdir}/system-generators/wendyos-boot-efi-generator
    chmod 0755 ${D}${systemd_unitdir}/system-generators/wendyos-boot-efi-generator
}

# The generator creates the mount and its local-fs.target dependency together.
# Replace the upstream postinstall, which creates a static mount dependency.
pkg_postinst:${PN}() {
    :
}

FILES:${PN} += "${systemd_unitdir}/system-generators/wendyos-boot-efi-generator"
RDEPENDS:${PN} += "util-linux-findmnt util-linux-blkid"
