SUMMARY = "WendyOS Arduino UNO Q-specific packages"
LICENSE = "MIT"
PACKAGE_ARCH = "${MACHINE_ARCH}"
inherit packagegroup

# Board drivers and firmware that meta-qcom, having no UNO Q machine, does not
# install. RDEPENDS, not RRECOMMENDS, for the reason packagegroup-wendyos-qcom
# gives: each absence is silent, so it must break the build instead.
#
#  anx7625             the USB-C port controller and DSI-to-DP bridge; it drives the
#                      role switch of the only dwc3 controller.
#  phy-qcom-*          that controller's USB2 and USB3 PHYs. Without them dwc3 never
#                      probes, so there is no gadget -- the board's host link.
#  spidev              the SPI link to the STM32 MCU.
#  uvcvideo            USB webcams on the USB-C port in host role.
RDEPENDS:${PN} = " \
    kernel-module-anx7625 \
    kernel-module-phy-qcom-qusb2 \
    kernel-module-phy-qcom-qmp-usbc \
    kernel-module-spidev \
    kernel-module-uvcvideo \
    "

# Wi-Fi firmware runs on the modem DSP: rmtfs and tqftpserv serve its storage and
# firmware files, and board-2.bin carries this board's calibration.
RDEPENDS:${PN} += " \
    kernel-module-ath10k-snoc \
    linux-firmware-ath10k-wcn3990 \
    linux-firmware-qcom-qcm2290-wifi \
    linux-firmware-qcom-qcm2290-modem \
    rmtfs \
    tqftpserv \
    wireless-regdb-static \
    "

# Firmware for the other blocks the device tree enables: Bluetooth, the Adreno GPU
# (which does not start without its zap shader), the audio DSP and the video codec.
RDEPENDS:${PN} += " \
    linux-firmware-qca-wcn3988 \
    linux-firmware-qcom-adreno-a702 \
    linux-firmware-qcom-qcm2290-adreno \
    linux-firmware-qcom-qcm2290-audio \
    linux-firmware-qcom-venus-6.0 \
    "

# The PMIC RTC keeps time only with a coin cell on VCOIN, so timesyncd's saved
# timestamp on /data is what keeps the clock sane across a reboot or an OTA swap.
RDEPENDS:${PN} += " systemd-mount-timesync"

# The factory Wi-Fi and Bluetooth addresses, which the slot's devicetree lacks.
RDEPENDS:${PN} += " wendyos-radio-addr"

# ABL counts down retries on its boot slot until a boot is marked good, then
# switches slots; qbootctl's bless service marks each completed boot.
RDEPENDS:${PN} += " qbootctl"

COMPATIBLE_MACHINE = "arduino-uno-q-wendyos"
