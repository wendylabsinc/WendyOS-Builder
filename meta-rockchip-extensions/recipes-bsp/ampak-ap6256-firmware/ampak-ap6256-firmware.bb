SUMMARY = "Firmware for the AMPAK AP6256 Wi-Fi/Bluetooth module (BCM43456 + BCM4345C5)"
DESCRIPTION = "brcmfmac SDIO firmware, regulatory CLM blob and AP6256 NVRAM for \
Wi-Fi, and the BCM4345C5 patch RAM for Bluetooth. linux-firmware ships none of \
them. Installed under the board-specific names the drivers ask for first."

# Wi-Fi firmware and CLM blob: Raspberry Pi's build for the same chip (Pi 400's
# BCM43456). The 2017 AP6256 build ran the WPA handshake itself and failed on
# WPA2/WPA3 routers; this one leaves it to the host.
RPIDISTRO_FW_REV = "b1833f18a816cf8fd73ca86e27f9eecea11bf991"
RPIDISTRO_FW_URI = "https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/${RPIDISTRO_FW_REV}"

# The module's NVRAM (RF calibration) and Bluetooth patch, as Armbian and the
# board vendor ship them; NOTICE.ap6256 records the source.
ARMBIAN_FW_REV = "db8cc456dad5ad511b04f8a5130acda392cad20b"
ARMBIAN_FW_URI = "https://raw.githubusercontent.com/armbian/firmware/${ARMBIAN_FW_REV}/brcm"

LICENSE = "LicenseRef-Synaptics-rpidistro AND LicenseRef-ampak-ap6256-CLOSED"
NO_GENERIC_LICENSE[Synaptics-rpidistro] = "rpidistro-firmware-nonfree-${RPIDISTRO_FW_REV}-copyright"
NO_GENERIC_LICENSE[ampak-ap6256-CLOSED] = "NOTICE.ap6256"
LIC_FILES_CHKSUM = " \
    file://rpidistro-firmware-nonfree-${RPIDISTRO_FW_REV}-copyright;md5=ef71bd8fbfc3d820a46061421760e8e9 \
    file://NOTICE.ap6256;md5=38a9318b844efedca28a49e34c2e7077 \
    "
# The Synaptics licence can be revoked; the same flag meta-raspberrypi sets.
LICENSE_FLAGS = "synaptics-killswitch"

SRC_URI = " \
    file://NOTICE.ap6256 \
    ${RPIDISTRO_FW_URI}/debian/copyright;name=license;downloadfilename=rpidistro-firmware-nonfree-${RPIDISTRO_FW_REV}-copyright \
    ${RPIDISTRO_FW_URI}/debian/added-firmware/brcm/brcmfmac43456-sdio.bin;name=fw;downloadfilename=rpidistro-${RPIDISTRO_FW_REV}-brcmfmac43456-sdio.bin \
    ${RPIDISTRO_FW_URI}/debian/added-firmware/brcm/brcmfmac43456-sdio.clm_blob;name=clm;downloadfilename=rpidistro-${RPIDISTRO_FW_REV}-brcmfmac43456-sdio.clm_blob \
    ${ARMBIAN_FW_URI}/brcmfmac43456-sdio.txt;name=nvram;downloadfilename=ap6256-${ARMBIAN_FW_REV}-brcmfmac43456-sdio.txt \
    ${ARMBIAN_FW_URI}/BCM4345C5.hcd;name=bt;downloadfilename=ap6256-${ARMBIAN_FW_REV}-BCM4345C5.hcd \
    "
SRC_URI[license.sha256sum] = "07082fd0bb65e32c73af39a2292dd6c83f169be7427d338ba1fe34f9b86c0e30"
SRC_URI[fw.sha256sum] = "dc4429f13b59f8c271e940c28b2a197455a8e02270fcc7a2f9036aa1e4c739fb"
SRC_URI[clm.sha256sum] = "2dbd7d22fc9af0eb560ceab45b19646d211bc7b34a1dd00c6bfac5dd6ba25e8a"
SRC_URI[nvram.sha256sum] = "66c71eb53b47c49d42386b66735134578640b0946f3f46e44f384fef5aacfd9e"
SRC_URI[bt.sha256sum] = "f67164f0eda8d4ca96305e177a61542bf8b470f2f1c456b66fe8c660650f1c7a"

S = "${UNPACKDIR}"

inherit allarch

# The board compatibles whose DTS describes an AP6256. brcmfmac asks for
# brcmfmac43456-sdio.<compatible>.{bin,txt}, and hci_bcm for
# BCM4345C5.<compatible>.hcd, before the generic names.
AP6256_BOARDS = "xunlong,orangepi-5-pro"

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/brcm
    for f in brcmfmac43456-sdio.bin brcmfmac43456-sdio.clm_blob; do
        install -m 0644 ${UNPACKDIR}/rpidistro-${RPIDISTRO_FW_REV}-$f ${D}${nonarch_base_libdir}/firmware/brcm/$f
    done
    for f in brcmfmac43456-sdio.txt BCM4345C5.hcd; do
        install -m 0644 ${UNPACKDIR}/ap6256-${ARMBIAN_FW_REV}-$f ${D}${nonarch_base_libdir}/firmware/brcm/$f
    done
    cd ${D}${nonarch_base_libdir}/firmware/brcm
    for board in ${AP6256_BOARDS}; do
        ln -sf brcmfmac43456-sdio.bin brcmfmac43456-sdio.$board.bin
        ln -sf brcmfmac43456-sdio.txt brcmfmac43456-sdio.$board.txt
        ln -sf brcmfmac43456-sdio.clm_blob brcmfmac43456-sdio.$board.clm_blob
        ln -sf BCM4345C5.hcd BCM4345C5.$board.hcd
    done
}

FILES:${PN} = "${nonarch_base_libdir}/firmware/brcm"

# linux-firmware-rpidistro ships the same generic file names for the Pi 400.
RCONFLICTS:${PN} = "linux-firmware-rpidistro-bcm43456"
