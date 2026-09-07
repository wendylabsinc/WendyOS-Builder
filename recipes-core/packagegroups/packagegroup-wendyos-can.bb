SUMMARY = "WendyOS SocketCAN support"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"
inherit packagegroup

# SocketCAN core, the transport protocols and every USB/SPI adapter driver.
#
# RRECOMMENDS, not RDEPENDS, because the set is not identical on every board and a
# missing one must not fail the build. Concretely: CAN_MCP251X/CAN_MCP251XFD sit
# behind "depends on SPI" (drivers/net/can/spi/Kconfig), and genericx86-64 has no
# CONFIG_SPI, so those two packages never exist there. With RRECOMMENDS the rpm
# backend treats them as weak deps and skips them (oe.package_manager.rpm honours
# dnf Recommends unless NO_RECOMMENDATIONS is set, which this distro does not set).
# The same pattern is already used, for the same reason, in
# packagegroup-wendyos-container.bb.
#
# Package names follow oe-core kernel-module-split.bbclass: the .ko basename with
# "_" -> "-", exposed unversioned via RPROVIDES. Verified against
# drivers/net/can/**/Makefile and against the Orin build's own deploy-rpms.
RRECOMMENDS:${PN} = " \
    kernel-module-can \
    kernel-module-can-raw \
    kernel-module-can-bcm \
    kernel-module-can-dev \
    kernel-module-can-isotp \
    kernel-module-can-j1939 \
    kernel-module-can-gw \
    kernel-module-vcan \
    kernel-module-slcan \
    kernel-module-gs-usb \
    kernel-module-usb-8dev \
    kernel-module-ems-usb \
    kernel-module-esd-usb \
    kernel-module-etas-es58x \
    kernel-module-f81604 \
    kernel-module-kvaser-usb \
    kernel-module-mcba-usb \
    kernel-module-peak-usb \
    kernel-module-ucan \
    kernel-module-mcp251x \
    kernel-module-mcp251xfd \
    "

# candump / cansend and friends are diagnostics only, so they ship in debug
# images. Bringing an interface up is `ip link set can0 up type can bitrate <n>`
# from iproute2, which is always present, so nothing operational depends on this.
RDEPENDS:${PN} = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_DEBUG') == '1', 'can-utils', '')} \
    "
