SUMMARY = "First-boot LUKS2 + TPM enrollment of the /data partition"
DESCRIPTION = "Ships /etc/crypttab (the /data TPM2 unlock entry), a first-boot \
oneshot (data-enroll.service) that grows the data partition, formats it LUKS2, \
seals a keyslot to the TPM, enrols a recovery key and makes the ext4 filesystem, \
and a drop-in ordering the enroll before the boot-time unlock. Board-agnostic; \
pulled into an image by the per-board image include when WENDYOS_ENABLE_TPM=1."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PR = "r0"

SRC_URI = " \
    file://data-enroll.sh \
    file://data-enroll.service \
    file://crypttab \
    file://10-enroll.conf \
    "

S = "${UNPACKDIR}"

# Board-agnostic, like grow-data-part: parsed on every machine but only pulled
# into an image when WENDYOS_ENABLE_TPM=1 (see the per-board image includes), so no
# COMPATIBLE_MACHINE restriction. The kernel TPM driver, the fstab -> /dev/mapper
# rewrite and the meta-tpm layer are wired per board.

# data-enroll.service is NOT enabled: it is pulled in and ordered by the drop-in
# (Requires=data-enroll.service on systemd-cryptsetup@data.service), so no [Install]
# / SYSTEMD_AUTO_ENABLE is needed. crypttab is consumed by systemd's crypttab
# generator automatically.
do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/data-enroll.sh ${D}${sbindir}/data-enroll.sh

    install -d ${D}${sysconfdir}
    install -m 0600 ${UNPACKDIR}/crypttab ${D}${sysconfdir}/crypttab

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/data-enroll.service ${D}${systemd_system_unitdir}/data-enroll.service

    install -d ${D}${systemd_system_unitdir}/systemd-cryptsetup@data.service.d
    install -m 0644 ${UNPACKDIR}/10-enroll.conf ${D}${systemd_system_unitdir}/systemd-cryptsetup@data.service.d/10-enroll.conf
}

CONFFILES:${PN} = "${sysconfdir}/crypttab"

FILES:${PN} = " \
    ${sbindir}/data-enroll.sh \
    ${sysconfdir}/crypttab \
    ${systemd_system_unitdir}/data-enroll.service \
    ${systemd_system_unitdir}/systemd-cryptsetup@data.service.d/10-enroll.conf \
    "

# cryptsetup: luksFormat/open/close/isLuks. systemd-crypt: systemd-cryptenroll +
# systemd-cryptsetup (the boot-time unlock). gptfdisk: sgdisk. parted: parted +
# partprobe. e2fsprogs-mke2fs: mkfs.ext4. coreutils: head/basename/readlink/cat.
# udev: udevadm settle.
RDEPENDS:${PN} = " \
    cryptsetup \
    systemd-crypt \
    gptfdisk \
    parted \
    e2fsprogs-mke2fs \
    coreutils \
    udev \
    "
