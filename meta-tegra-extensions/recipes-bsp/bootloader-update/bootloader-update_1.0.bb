SUMMARY = "Bootloader update marker file for UEFI capsule updates"
DESCRIPTION = "Installs the marker file (/var/lib/wendyos/update-bootloader) that \
tells the wendyos-update tegrauefi connector to stage the UEFI bootloader \
capsule to the ESP during an A/B swap, for atomic rootfs+bootloader updates."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# This is a marker-only package, no source files needed
ALLOW_EMPTY:${PN} = "1"

do_install() {
    # Create the bootloader update marker file — read by the wendyos-update
    # tegrauefi connector (MarkerPath) to decide whether to stage the capsule
    install -d ${D}${localstatedir}/lib/wendyos
    touch ${D}${localstatedir}/lib/wendyos/update-bootloader
}

FILES:${PN} = "${localstatedir}/lib/wendyos/update-bootloader"

PACKAGE_ARCH = "${MACHINE_ARCH}"
