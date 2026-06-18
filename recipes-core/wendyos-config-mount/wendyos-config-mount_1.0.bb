SUMMARY = "Mount the WendyOS config partition at /config"
DESCRIPTION = "Provides a systemd service that mounts the FAT32 config \
partition by filesystem label using blkid, without relying on the \
/dev/disk/by-label/config udev symlink (absent on some platforms such as \
Jetson Thor / T264)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# RPi has the config fstab entry in rpi-fstab (udev by-label works there).
# This recipe is only needed on Tegra where by-label links are unreliable.
COMPATIBLE_MACHINE = "(tegra)"

SRC_URI = " \
    file://wendyos-config-mount.sh \
    file://wendyos-config-mount.service \
"

S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "wendyos-config-mount.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = "util-linux"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-config-mount.sh \
        ${D}${sbindir}/wendyos-config-mount.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-config-mount.service \
        ${D}${systemd_system_unitdir}/

    # Create the /config mount point in the rootfs.
    install -d ${D}/config
}

FILES:${PN} += " \
    ${sbindir}/wendyos-config-mount.sh \
    ${systemd_system_unitdir}/wendyos-config-mount.service \
    /config \
"
