SUMMARY = "Grow /data to fill the storage device on first boot (RPi)"
DESCRIPTION = "First-boot oneshot that grows /data to fill the storage device, \
no reboot. /data is the last partition because config is placed before it by \
the rpi-wendy-ab*.wks layouts; this also grows the MBR extended container and \
relocates the GPT backup header (wendy A/B \
layout) so the partition can reach the disk end. Split in two phases: the fast \
partition grow runs offline before data.mount (grow-data-part.service), the slow \
ext4 resize2fs runs online afterwards off the boot path (grow-data-fs-online.service)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PR = "r0"

SRC_URI = " \
    file://grow-data-part.sh \
    file://grow-data-part.service \
    file://grow-data-fs-online.service \
    "

S = "${UNPACKDIR}"

inherit systemd

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/grow-data-part.sh ${D}${sbindir}/grow-data-part.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/grow-data-part.service ${D}${systemd_system_unitdir}/grow-data-part.service
    install -m 0644 ${UNPACKDIR}/grow-data-fs-online.service ${D}${systemd_system_unitdir}/grow-data-fs-online.service
}

FILES:${PN} += " \
    ${sbindir}/grow-data-part.sh \
    ${systemd_system_unitdir}/grow-data-part.service \
    ${systemd_system_unitdir}/grow-data-fs-online.service \
    "

# Both phase units auto-enabled so each A/B slot wants them (ordering in the units:
# grow-data-part.service = phase 1 offline before data.mount; grow-data-fs-online =
# phase 2 online after data.mount).
SYSTEMD_SERVICE:${PN} = "grow-data-part.service grow-data-fs-online.service"
SYSTEMD_AUTO_ENABLE = "enable"

# Phase 1 runs offline (before local-fs-pre.target): reads /data from fstab, finds
# partitions via sysfs. coreutils for cat/readlink -f/basename; util-linux-sfdisk
# detects the MBR extended partition; util-linux-findfs resolves the LABEL=/PARTUUID=
# /data spec (wendy fstab); gptfdisk provides sgdisk -e (relocate GPT backup header);
# parted provides parted + partprobe; e2fsprogs for resize2fs (phase 2) + the
# clean-flag e2fsck (phase 1); udev for udevadm settle. awk assumed present from the
# base image (busybox/gawk).
RDEPENDS:${PN} = " \
    bash \
    coreutils \
    util-linux-sfdisk \
    util-linux-findfs \
    gptfdisk \
    parted \
    e2fsprogs-resize2fs \
    e2fsprogs-e2fsck \
    udev \
    "

COMPATIBLE_MACHINE = "rpi"

