SUMMARY = "Grow /data to fill the storage device on first boot (RPi)"
DESCRIPTION = "First-boot oneshot that grows /data to fill the storage device \
(offline, no reboot). /data is the last partition because config is placed before \
it by mender-config-before-data.bbclass; this also grows the MBR extended container \
that Mender's mender-growfs-data cannot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PR = "r0"

SRC_URI = " \
    file://grow-data-part.sh \
    file://grow-data-part.service \
"

S = "${WORKDIR}"

inherit systemd

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/grow-data-part.sh ${D}${sbindir}/grow-data-part.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/grow-data-part.service ${D}${systemd_system_unitdir}/grow-data-part.service
}

FILES:${PN} += " \
    ${sbindir}/grow-data-part.sh \
    ${systemd_system_unitdir}/grow-data-part.service \
"

SYSTEMD_SERVICE:${PN} = "grow-data-part.service"
SYSTEMD_AUTO_ENABLE = "enable"

# Runs offline (before local-fs-pre.target): reads /data from fstab, finds
# partitions via sysfs. coreutils for cat/readlink -f/basename; util-linux-sfdisk
# detects the MBR extended partition; parted provides parted + partprobe;
# e2fsprogs for resize2fs (+ e2fsck only when an unclean fs refuses resize); udev
# for udevadm settle. awk is assumed present from the base image (busybox/gawk).
RDEPENDS:${PN} = " \
    bash \
    coreutils \
    util-linux-sfdisk \
    util-linux-findfs \
    parted \
    e2fsprogs-resize2fs \
    e2fsprogs-e2fsck \
    udev \
"

COMPATIBLE_MACHINE = "rpi"
