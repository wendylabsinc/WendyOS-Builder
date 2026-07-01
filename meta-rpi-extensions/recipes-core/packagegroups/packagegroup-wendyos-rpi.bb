SUMMARY = "WendyOS RPi-specific packages"
LICENSE = "MIT"
PACKAGE_ARCH = "${MACHINE_ARCH}"
inherit packagegroup

RDEPENDS:${PN} = " \
    wireless-regdb-static \
    ${@'' if d.getVar('WENDYOS_OTA') == 'wendy' else 'expand-rootfs'} \
    grow-data-part \
    first-boot-timesync \
    pi-bluetooth \
    "
# expand-rootfs grows the ROOT partition to fill the card — correct for the
# single-rootfs Mender layout, but fatal for the wendy A/B layout (it would
# grow rootfsA over rootfsB). Excluded when WENDYOS_OTA="wendy"; grow-data-part
# (kept) grows /data, the last partition, instead.
# pi-bluetooth ships hciuart.service, which attaches the onboard BT radio to
# the system over UART on RPi3/4/5. Upstream meta-raspberrypi already pulls
# it in via RDEPENDS:bluez5:append:rpi, but declare it explicitly here so we
# don't silently lose BT if that bbappend ever changes.
# rpi-eeprom-config writes the RPi5 board EEPROM (PSU_MAX_CURRENT, PCIE_PROBE,
# BOOT_ORDER) so the board boots either SD or NVMe regardless of which image
# flashed it. These are RPi5-only EEPROM keys (BCM2712); RPi4's EEPROM differs
# and RPi3 has none, and the runtime script skips on non-RPi5. Include only on
# RPi5 to keep it out of RPi4/RPi3 builds.
RDEPENDS:${PN}:append:raspberrypi5 = " rpi-eeprom-config"

# Camera stack. Mirrors stock Raspberry Pi OS so an official CSI camera
# (IMX219/IMX477/IMX708), auto-detected via camera_auto_detect=1 in the Pi 5
# config.txt (raspberrypi5-wendyos.conf), enumerates and streams out of the box:
#   - libcamera     : core library plus the `cam` tool (the agent runs
#                     `cam --list` to discover CSI cameras; the binary ships in
#                     the main libcamera package).
#   - libcamera-gst : the `libcamerasrc` GStreamer element the agent's video
#                     pipeline streams through on CSI cameras.
# Both the gstreamer element and the PiSP pipeline they rely on are enabled by
# the meta-rpi-extensions libcamera bbappend; the gstreamer runtime itself is
# already in the shared image (recipes-core/images/wendyos-image.bb).
RDEPENDS:${PN} += " \
    libcamera \
    libcamera-gst \
    "

RDEPENDS:${PN}:append = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_DEBUG') == '1', ' iw mmc-utils v4l-utils', '')} \
    "

COMPATIBLE_MACHINE = "rpi"
