SUMMARY = "Arduino UNO Q boot firmware"
DESCRIPTION = "The ABL boot chain Arduino ships for the UNO Q, derived from the \
Linaro RB1 release. Its boot.img is Arduino's U-Boot, which ABL loads from \
boot_a/boot_b and which runs GRUB from the ESP."

LICENSE = "LicenseRef-LICENSE.qcom"
LIC_FILES_CHKSUM = "file://LICENSE;md5=cbbe399f2c983ad51768f4561587f000"

SRC_URI = "https://downloads.arduino.cc/debian-im/unoq-bootloader-emmc-linux-${PV}.zip"
SRC_URI[sha256sum] = "c606e95d0107f8c58d0dd9494e00624d1db7c4361cca20513bc78ef02ca28dd1"

BOOTBINARIES = "unoq-bootloader-emmc-linux-${PV}"
QCOM_BOOT_IMG_SUBDIR = "arduino-uno-q"

require recipes-bsp/firmware-boot/firmware-qcom-boot-common.inc

# The common deploy skips images.
do_deploy:append() {
    install -m 0644 ${S}/boot.img ${DEPLOYDIR}/${QCOM_BOOT_IMG_SUBDIR}/
}
