SUMMARY = "Orange Pi 5 Pro hardware support for WendyOS"
DESCRIPTION = "Firmware the Orange Pi 5 Pro's hardware needs at runtime. Hard \
RDEPENDS, so a missing package fails the build instead of a device."
LICENSE = "MIT"

PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "orangepi-5-pro-wendyos"

inherit packagegroup

RDEPENDS:${PN} = " \
    ampak-ap6256-firmware \
    linux-firmware-mali-csffw-arch108 \
    wireless-regdb-static \
    "
