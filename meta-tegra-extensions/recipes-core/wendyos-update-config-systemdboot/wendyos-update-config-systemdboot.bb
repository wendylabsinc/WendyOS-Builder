SUMMARY = "wendyos-update connector config for Jetson systemd-boot A/B (systemdboot)"
DESCRIPTION = "Installs /etc/wendyos-update/config.json pinning the wendyos-update \
OTA client to the systemdboot connector on the Jetson systemd-boot A/B boot path. \
The connector MUST be pinned: auto-detect would otherwise pick tegrauefi \
(nvbootctrl is present) and drive NVIDIA's firmware A/B mechanism, whose \
RootfsRedundancyLevel is unarmable from the OS on Orin. Jetson analogue of the \
RPi wendyos-update-config. Only built into the image when \
WENDYOS_TEGRA_SYSTEMDBOOT_AB = 1."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = "file://config.json"
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "(tegra)"

do_install() {
    install -d ${D}${sysconfdir}/wendyos-update
    install -m 0644 ${UNPACKDIR}/config.json ${D}${sysconfdir}/wendyos-update/config.json
}

# The config dir is also created by the wendyos-update recipe (the <phase>.d
# hook dirs); allow both to ship it.
FILES:${PN} = "${sysconfdir}/wendyos-update/config.json"
