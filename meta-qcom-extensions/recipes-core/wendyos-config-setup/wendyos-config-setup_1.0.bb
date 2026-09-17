SUMMARY = "First-boot FAT32 setup for the Dragonwing /config partition"
DESCRIPTION = "qcom-ptool allocates the config partition but leaves it raw (no \
--filename in partitions.conf), so unlike the wic-built boards nothing creates a \
filesystem on it. This is the /config counterpart to wendyos-data-setup, which \
does the same job for /data on the allocate-empty platforms."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://wendyos-config-init.sh file://wendyos-config-init.service \
           file://config.mount"
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "iq-8275-evk-wendyos"

inherit systemd
SYSTEMD_SERVICE:${PN} = "wendyos-config-init.service config.mount"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = "coreutils dosfstools util-linux-blkid"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/wendyos-config-init.sh ${D}${bindir}/
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-config-init.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/config.mount ${D}${systemd_system_unitdir}/
}
