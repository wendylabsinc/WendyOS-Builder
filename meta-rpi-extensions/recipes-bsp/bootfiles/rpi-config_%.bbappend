# Only runs on RPi machines (rpi-config recipe only exists in meta-raspberrypi)
# RPi5 needs dtoverlay=uart0 to map PL011 to GPIO 14/15 (yields /dev/ttyAMA0).
# RPi3/4 use the upstream default: PL011 stays on Bluetooth, serial console
# runs on the mini UART (/dev/ttyS0) via enable_uart=1 set in their machine
# configs. Do NOT apply dtoverlay=uart0 for all :rpi — on RPi3/4 it would
# steal PL011 from Bluetooth.
# DEBUG AID (blacksail RPi5 bring-up): emit early RP1 UART debug on GPIO 14/15.
# The Pi5 firmware/U-Boot EARLY output is hardwired to the dedicated 3-pin debug
# connector (the GPIO14/15 UART is on RP1, only alive after PCIe is up), so it
# cannot appear on the 40-pin header. `enable_rp1_uart=1` is the most GPIO-14/15
# can show: the firmware keeps RP1 UART0 alive and emits some early "RP1_UART"
# debug there. (earlycon is NOT added — verified ineffective on GPIO14/15.)
# Gated to the blacksail tree so the validated scarthgap rpi5 is untouched.
# Remove once RPi5-on-blacksail boots (or once a dedicated-connector debug shows
# the real failure).
WENDYOS_RPI5_DEBUG_CONFIG = "${@'enable_rp1_uart=1' if 'blacksail' in (d.getVar('LAYERSERIES_CORENAMES') or '').split() else ''}"

do_deploy:append:raspberrypi5() {
    # enable_uart=1 is already written by the upstream rpi-config recipe when
    # ENABLE_UART=1 (set in raspberrypi5-wendyos.conf). Do not duplicate it here.
    echo "dtoverlay=uart0" >> "${DEPLOYDIR}/${BOOTFILES_DIR_NAME}/config.txt"
    # Note: dtoverlay=dwc2,dr_mode=peripheral is written by the upstream rpi-config
    # recipe when ENABLE_DWC2_PERIPHERAL=1 (set in raspberrypi5-wendyos.conf).
    # Do NOT add a second dtoverlay=dwc2 here — it would override dr_mode=peripheral.
    if [ -n "${WENDYOS_RPI5_DEBUG_CONFIG}" ]; then
        echo "${WENDYOS_RPI5_DEBUG_CONFIG}" >> "${DEPLOYDIR}/${BOOTFILES_DIR_NAME}/config.txt"
    fi
}

