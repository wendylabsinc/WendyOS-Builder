SUMMARY = "wendyos-update connector config for the WendyOS VM machines (grubenv)"
DESCRIPTION = "Installs /etc/wendyos-update/config.json pinning the wendyos-update \
OTA client to the grubenv connector. Auto-detect would also pick it (grub-editenv \
present + our env layout), but a build-time pin is one less runtime failure mode. \
Sibling of meta-x86-extensions' recipe of the same name; the two never coexist in \
one build because the VM boards do not layer meta-x86-extensions."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://config.json"
S = "${UNPACKDIR}"

# Both VM machines: the connector is the bootloader interface, and both boot the
# same GRUB-EFI + grubenv A/B chain. re.search'd against MACHINE, so an
# alternation covers the pair without matching anything else.
COMPATIBLE_MACHINE = "vm-x86-64-wendyos|vm-arm64-wendyos"

do_install() {
    install -d ${D}${sysconfdir}/wendyos-update
    install -m 0644 ${UNPACKDIR}/config.json ${D}${sysconfdir}/wendyos-update/config.json
}

# The config dir is also created by the wendyos-update recipe (the <phase>.d
# hook dirs); allow both to ship it.
FILES:${PN} = "${sysconfdir}/wendyos-update/config.json"

