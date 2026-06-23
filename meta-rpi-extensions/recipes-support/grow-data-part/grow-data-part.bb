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
    file://grow-data-fs-online.service \
"

S = "${WORKDIR}"

inherit systemd

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/grow-data-part.sh ${D}${sbindir}/grow-data-part.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/grow-data-part.service ${D}${systemd_system_unitdir}/grow-data-part.service
    install -m 0644 ${WORKDIR}/grow-data-fs-online.service ${D}${systemd_system_unitdir}/grow-data-fs-online.service
}

FILES:${PN} += " \
    ${sbindir}/grow-data-part.sh \
    ${systemd_system_unitdir}/grow-data-part.service \
    ${systemd_system_unitdir}/grow-data-fs-online.service \
"

# Both phase units auto-enabled so each Mender A/B slot wants them (mechanics in
# the unit files).
SYSTEMD_SERVICE:${PN} = "grow-data-part.service grow-data-fs-online.service"
SYSTEMD_AUTO_ENABLE = "enable"

# Runtime tools: coreutils (cat/readlink/basename); util-linux-sfdisk (detect MBR
# extended partition); parted (parted + partprobe); e2fsprogs (resize2fs + the
# clean-flag e2fsck); udev (udevadm settle). awk assumed present from the base image.
RDEPENDS:${PN} = " \
    bash \
    coreutils \
    util-linux-sfdisk \
    parted \
    e2fsprogs-resize2fs \
    e2fsprogs-e2fsck \
    udev \
"

COMPATIBLE_MACHINE = "rpi"
