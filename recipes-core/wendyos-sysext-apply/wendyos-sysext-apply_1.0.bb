SUMMARY = "Merge WendyOS driver add-ons (systemd-sysext) from /data at boot"
DESCRIPTION = "Late-boot service that merges driver .raw add-ons stored on /data onto the \
running /usr with a writable (ephemeral) layer so depmod can index them, then modprobes \
the modules each add-on declares — so a driver can be installed at runtime without \
rebuilding the OS image."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://wendyos-sysext-apply.sh \
    file://wendyos-sysext-apply.service \
"
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "wendyos-sysext-apply.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -D -m 0755 ${UNPACKDIR}/wendyos-sysext-apply.sh \
        ${D}${sbindir}/wendyos-sysext-apply.sh
    install -D -m 0644 ${UNPACKDIR}/wendyos-sysext-apply.service \
        ${D}${systemd_system_unitdir}/wendyos-sysext-apply.service
}

FILES:${PN} += " \
    ${sbindir}/wendyos-sysext-apply.sh \
    ${systemd_system_unitdir}/wendyos-sysext-apply.service \
"

# systemd-sysext comes from systemd's sysext PACKAGECONFIG; depmod/modprobe from kmod.
RDEPENDS:${PN} = "systemd kmod"
