SUMMARY = "WendyOS SocketCAN support"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"
inherit packagegroup

# SocketCAN core, the transport protocols and every USB/SPI adapter driver.
# RRECOMMENDS, not RDEPENDS, so a module a kernel does not build does not fail
# the image. Package names are the module names with "_" turned into "-".
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
