SUMMARY = "Keep NVIDIA's out-of-tree rtk_btusb off the Realtek BT radio"
DESCRIPTION = "Jetson Orin Nano devkits use mainline btusb+btrtl for the \
RTL8822CE Bluetooth radio; the vendor rtk_btusb driver drops BLE HID links \
in a ~2 s connect/drop loop. Its packages are removed from the image, and \
this modprobe policy guarantees a stray copy (stale OTA overlay, future \
packaging regression) can never bind the radio first."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI = "file://rtk-btusb-blacklist.conf"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${UNPACKDIR}/rtk-btusb-blacklist.conf ${D}${sysconfdir}/modprobe.d/
}
