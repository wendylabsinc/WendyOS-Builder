SUMMARY = "wendyos-update connector config for Qualcomm Dragonwing (grubenv)"
DESCRIPTION = "Installs /etc/wendyos-update/config.json pinning the wendyos-update \
OTA client to the grubenv connector. Auto-detect would also pick it (grub-editenv \
present + our env layout), but a build-time pin is one less runtime failure mode. \
Same connector the generic x86-64 board uses -- this board reaches GRUB via the \
SoC's own UEFI rather than via a PC BIOS, but the A/B state lives in the same \
EFI/BOOT/grubenv, so the connector is unchanged."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://config.json"
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "iq-8275-evk-wendyos"

do_install() {
    install -d ${D}${sysconfdir}/wendyos-update
    install -m 0644 ${UNPACKDIR}/config.json ${D}${sysconfdir}/wendyos-update/config.json
}

# The config dir is also created by the wendyos-update recipe (the <phase>.d
# hook dirs); allow both to ship it.
FILES:${PN} = "${sysconfdir}/wendyos-update/config.json"
