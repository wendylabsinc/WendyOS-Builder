FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Raspberry Pi 5 (BCM2712): the U-Boot version validated on the Pi 5, plus
# 0001-nvme-phys-to-bus.patch (not upstream) so its NVMe driver works behind the
# BCM2712 PCIe controller. Move to oe-core's U-Boot once it is validated here.
#
# The wildcard filename keeps this append from dangling on the rpi3/rpi4 U-Boot,
# where the :raspberrypi5 overrides are inert.
SRC_URI:raspberrypi5 = "git://source.denx.de/u-boot/u-boot.git;protocol=https;branch=master"
SRCREV:raspberrypi5 = "1296a428c67cf103eca482d4a63349661c1b799f"

SRC_URI:append:raspberrypi5 = " \
    file://rpi5-bootdelay.cfg \
    file://rpi5-boot.cfg \
    file://0001-nvme-phys-to-bus.patch \
    "
