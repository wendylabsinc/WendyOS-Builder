SUMMARY = "Bluetooth controller bring-up for WendyOS Tegra"
DESCRIPTION = "Autoloads the USB HCI transport and pulls in the kernel \
Bluetooth modules and controller firmware so the BT radio registers as hci0 \
and BlueZ exposes an adapter (Adapter1 / LEAdvertisingManager1) on D-Bus."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI = "file://bluetooth-modules.conf"

S = "${UNPACKDIR}"

# Tegra-only: the controller assumptions and firmware here target the Jetson
# AGX Thor / Orin combo cards. COMPATIBLE_MACHINE keeps it off other machines
# even though only the Tegra packagegroup pulls it.
COMPATIBLE_MACHINE = "(tegra)"

do_install() {
    install -d ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${UNPACKDIR}/bluetooth-modules.conf ${D}${sysconfdir}/modules-load.d/
}

# Kernel modules built by the bluetooth.cfg fragment in the jp7
# linux-noble-nvidia-tegra bbappend. btusb pulls btrtl/btbcm at probe time;
# list btrtl explicitly so the .ko is guaranteed present in the image.
RDEPENDS:${PN} += " \
    kernel-module-btusb \
    kernel-module-btrtl \
    "

# Controller firmware. UNVERIFIED: assumes a Realtek combo, as on the AGX Orin
# DevKit. linux-firmware-rtl-bt ships rtl_bt/*.bin. Swap for the matching
# vendor package (e.g. linux-firmware-broadcom-bcm / linux-firmware-intel-bt)
# once the AGX Thor DevKit's BT controller is confirmed on hardware.
RDEPENDS:${PN} += " linux-firmware-rtl-bt"
