SUMMARY = "Build the in-tree gs_usb driver as an external module"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"
SRC_URI = "file://Makefile"
S = "${UNPACKDIR}"
inherit module
COMPATIBLE_MACHINE = "jetson-agx-thor.*"
do_compile:prepend() {
    cp ${STAGING_KERNEL_DIR}/drivers/net/can/usb/gs_usb.c ${S}/gs_usb.c
}
