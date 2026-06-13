SUMMARY = "Reclaim the consumed /config partition into /data on first boot"
DESCRIPTION = "After wendy-agent consumes the first-boot provisioning files from \
the FAT32 /config partition, this oneshot deletes that partition and grows /data \
to fill the storage device. It restores the grow-to-any-card sizing that Mender's \
mender-growfs-data provides on stock layouts but cannot once an extra partition \
sits after /data (see raspberrypi-common-wendyos.inc)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PR = "r0"

SRC_URI = " \
    file://reclaim-config-part.sh \
    file://reclaim-config-part.service \
"

S = "${WORKDIR}"

inherit systemd

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/reclaim-config-part.sh ${D}${sbindir}/reclaim-config-part.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/reclaim-config-part.service ${D}${systemd_system_unitdir}/reclaim-config-part.service
}

FILES:${PN} += " \
    ${sbindir}/reclaim-config-part.sh \
    ${systemd_system_unitdir}/reclaim-config-part.service \
"

SYSTEMD_SERVICE:${PN} = "reclaim-config-part.service"
SYSTEMD_AUTO_ENABLE = "enable"

# parted provides parted + partprobe; util-linux-* for sfdisk/lsblk/findmnt;
# e2fsprogs-resize2fs for resize2fs; udev for udevadm settle. mount/umount come
# from the base image (busybox and/or util-linux).
RDEPENDS:${PN} = " \
    bash \
    coreutils \
    util-linux-sfdisk \
    util-linux-lsblk \
    util-linux-findmnt \
    parted \
    e2fsprogs-resize2fs \
    udev \
"

COMPATIBLE_MACHINE = "rpi"
