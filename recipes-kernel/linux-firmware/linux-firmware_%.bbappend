# Narrow Intel and MediaTek Wi-Fi/Bluetooth firmware packages.
#
# oe-core splits linux-firmware per chip for the older Intel parts (-iwlwifi-9260,
# -ibt-20, ...) but lumps every newer Intel Wi-Fi blob into -iwlwifi-misc (249 MB in
# 20260622: AX201, AX211, BE200 and the rest) and every Intel Bluetooth blob into
# -ibt-misc (24 MB). MediaTek is not split at all: -mediatek is the whole directory
# (74 MB, mostly access-point SoCs). The Tegra image installs firmware by package
# name (conf/distro/include/tegra-image.inc) into a size-pinned A/B rootfs slot, so
# carve out just the discrete M.2 E-key parts a Jetson can actually take:
#
#   -iwlwifi-ax210  iwlwifi-ty-a0-gf-a0-*.ucode + .pnvm  (AX210 / AX1675)   21 MB
#   -iwlwifi-ax200  iwlwifi-cc-a0-*.ucode                (AX200 / AX1650)    9 MB
#   -ibt-ax210      intel/ibt-0041-0041.{sfi,ddc}        (AX210 Bluetooth)   1 MB
#   -mt7921         MT7961 + MT7922 Wi-Fi and Bluetooth  (MT7921 / MT7922)   5 MB
#
# PACKAGES:prepend puts them ahead of the upstream catch-alls, and packaging hands
# each file to the first package whose FILES matches, so these claim their blobs
# before -iwlwifi-misc, -ibt-misc and -mediatek do. The upstream meta-packages
# still pull them in: populate_packages:prepend recommends every package it finds
# in PACKAGES, so an image that installs plain linux-firmware (x86) is unchanged.
#
# Globs follow upstream's -iwlwifi-* entries: the top-level name the 6.8 driver
# requests plus the intel/iwlwifi/ directory it links into since linux-firmware
# 2025 (copy-firmware.sh creates the link from WHENCE at install time, and a link
# packaged apart from its target would dangle), with a trailing * so a
# FIRMWARE_COMPRESSION suffix still matches.
PACKAGES:prepend = "${PN}-iwlwifi-ax210 ${PN}-iwlwifi-ax200 ${PN}-ibt-ax210 ${PN}-mt7921 "

LICENSE:${PN}-iwlwifi-ax210 = "LicenseRef-Firmware-iwlwifi-firmware"
FILES:${PN}-iwlwifi-ax210 = " \
    ${firmwaredir}/iwlwifi-ty-a0-gf-a0-*.ucode* \
    ${firmwaredir}/iwlwifi-ty-a0-gf-a0.pnvm* \
    ${firmwaredir}/intel/iwlwifi/iwlwifi-ty-a0-gf-a0-*.ucode* \
    ${firmwaredir}/intel/iwlwifi/iwlwifi-ty-a0-gf-a0.pnvm* \
"
RDEPENDS:${PN}-iwlwifi-ax210 = "${PN}-iwlwifi-license"

LICENSE:${PN}-iwlwifi-ax200 = "LicenseRef-Firmware-iwlwifi-firmware"
FILES:${PN}-iwlwifi-ax200 = " \
    ${firmwaredir}/iwlwifi-cc-a0-*.ucode* \
    ${firmwaredir}/intel/iwlwifi/iwlwifi-cc-a0-*.ucode* \
"
RDEPENDS:${PN}-iwlwifi-ax200 = "${PN}-iwlwifi-license"

LICENSE:${PN}-ibt-ax210 = "LicenseRef-Firmware-ibt-firmware"
FILES:${PN}-ibt-ax210 = "${firmwaredir}/intel/ibt-0041-0041.*"
RDEPENDS:${PN}-ibt-ax210 = "${PN}-ibt-license"

# mt7921e drives both MT7921 (MT7961 blobs) and MT7922; btusb/btmtk load the
# matching BT_RAM_CODE for the Bluetooth function.
LICENSE:${PN}-mt7921 = "LicenseRef-Firmware-mediatek"
FILES:${PN}-mt7921 = " \
    ${firmwaredir}/mediatek/WIFI_RAM_CODE_MT7961_*.bin* \
    ${firmwaredir}/mediatek/WIFI_MT7961_patch_mcu_*.bin* \
    ${firmwaredir}/mediatek/BT_RAM_CODE_MT7961_*.bin* \
    ${firmwaredir}/mediatek/WIFI_RAM_CODE_MT7922_*.bin* \
    ${firmwaredir}/mediatek/WIFI_MT7922_patch_mcu_*.bin* \
    ${firmwaredir}/mediatek/BT_RAM_CODE_MT7922_*.bin* \
"
RDEPENDS:${PN}-mt7921 = "${PN}-mediatek-license"
