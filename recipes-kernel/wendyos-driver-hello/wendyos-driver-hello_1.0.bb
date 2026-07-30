SUMMARY = "WendyOS sysext driver-pipeline self-test kernel module"
DESCRIPTION = "A trivial out-of-tree module that validates the driver add-on \
pipeline (compile -> sysext .raw -> merge -> depmod -> modprobe) end to end on \
real hardware, without an accelerator. Stand-in for a real vendor driver."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

inherit wendyos-driver-module

SRC_URI = " \
    file://Makefile \
    file://wendyos_hello.c \
"

# file:// sources unpack to ${UNPACKDIR} (= ${WORKDIR}/sources on current oe-core).
S = "${UNPACKDIR}"
