FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Raspberry Pi 5 (BCM2712) runs U-Boot v2026.07-rc4: oe-core's v2026.04 lacks
# the BCM2712 PCIe driver NVMe boot needs, and never booted a Pi 5 here.
# 0001-nvme-phys-to-bus.patch (not upstream) translates NVMe DMA addresses:
# BCM2712 maps PCIe bus 0x10_00000000 to CPU 0x0, and stock nvme.c programs CPU
# addresses, so nvme_init times out.
#
# The wildcard filename keeps this append from dangling on the rpi3/rpi4 U-Boot,
# where the :raspberrypi5 overrides are inert. Repin to a stable release, and
# drop the patch once the fix is upstream.
SRC_URI:raspberrypi5 = "git://source.denx.de/u-boot/u-boot.git;protocol=https;branch=master"
SRCREV:raspberrypi5 = "1296a428c67cf103eca482d4a63349661c1b799f"

SRC_URI:append:raspberrypi5 = " \
    file://rpi5-bootdelay.cfg \
    file://rpi5-boot.cfg \
    file://0001-nvme-phys-to-bus.patch \
    "
