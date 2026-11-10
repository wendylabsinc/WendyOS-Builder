SUMMARY = "Flash and GPIO helpers for the Arduino UNO Q microcontroller"
DESCRIPTION = "Writes the STM32's firmware over its SWD link to the TLMM GPIOs \
with OpenOCD, the way Arduino's upload does, and sets the MCU control lines."
# MIT: mcu-flash and mcu-gpio. GPL-2.0-or-later: the OpenOCD configs. Apache-2.0: flash- and resume-zephyr-1.cfg.
LICENSE = "MIT & GPL-2.0-or-later & Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302 \
                    file://${COMMON_LICENSE_DIR}/GPL-2.0-or-later;md5=fed54355545ffd980b814dab4a3b312c \
                    file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

# The OpenOCD configs and Tcl helpers come from arduino/meta-arduino at
# d0fcc1e423797e518f8901d8cb930ccddaea67fc (meta-arduino-qcom/recipes-devtools/
# openocd/files/imola). sha256 as fetched:
#   openocd_gpiod.cfg    58c0c341ba2a0c758bb044683884fb4af01ff6c9cf292bec6b2115c44f7ff836
#                        (here with -chip 1 replaced by -chip $mcu_chip)
#   stm32u5x.cfg         8c0ffc41eadd0593168b825d60d6736329c08974c047fdac722fabb93c0ee46a
#   stm32x5x_common.cfg  139a2c4167e4fc649ab0057560858e03a24dcafeb5b0b3a3bcb7b9373e0869e4
#   mem_helper.tcl       01794a37e9a8bdc20e2304ee64e9d70549c0872f5f6c40fa032a165bcbba1fd2
#   target/swj-dp.tcl    aad132008735bbafea3d18a304632c638f0fb99bfc19530c9f577eda2b10410a
# flash-zephyr-1.cfg is ArduinoCore-zephyr 1.1.0's variant flash_sketch.cfg, with
# the sketch address as ${sketch_addr}, an echo and a verify after each write, and
# its closing restart moved to resume-zephyr-1.cfg.
SRC_URI = " \
    file://mcu-flash \
    file://mcu-gpio \
    file://flash-zephyr-1.cfg \
    file://resume-zephyr-1.cfg \
    file://openocd_gpiod.cfg \
    file://stm32u5x.cfg \
    file://stm32x5x_common.cfg \
    file://mem_helper.tcl \
    file://target/swj-dp.tcl \
    "
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "arduino-uno-q-wendyos"

RDEPENDS:${PN} = "openocd libgpiod-tools"

do_install() {
    install -d ${D}${libexecdir}/wendyos ${D}${datadir}/wendyos/mcu/target
    install -m 0755 ${UNPACKDIR}/mcu-flash ${UNPACKDIR}/mcu-gpio ${D}${libexecdir}/wendyos/
    for f in flash-zephyr-1.cfg resume-zephyr-1.cfg openocd_gpiod.cfg stm32u5x.cfg stm32x5x_common.cfg mem_helper.tcl; do
        install -m 0644 ${UNPACKDIR}/$f ${D}${datadir}/wendyos/mcu/
    done
    install -m 0644 ${UNPACKDIR}/target/swj-dp.tcl ${D}${datadir}/wendyos/mcu/target/
}

FILES:${PN} += "${datadir}/wendyos/mcu"
