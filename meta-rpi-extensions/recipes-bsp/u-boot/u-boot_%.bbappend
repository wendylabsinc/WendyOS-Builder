FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Raspberry Pi 5 (BCM2712): oe-core's stock U-Boot v2026.07, plus
# 0001-nvme-phys-to-bus.patch (not upstream) so its NVMe driver works behind the
# BCM2712 PCIe controller, and the config fragments for the one image that boots
# from SD or NVMe. These were validated on 2026.07-rc4, which is an ancestor of
# v2026.07; the commits between them do not touch drivers/nvme or drivers/pci.
#
# The wildcard filename keeps this append from dangling on the rpi3/rpi4 U-Boot,
# where the :raspberrypi5 overrides are inert.
SRC_URI:append:raspberrypi5 = " \
    file://rpi5-bootdelay.cfg \
    file://rpi5-boot.cfg \
    file://0001-nvme-phys-to-bus.patch \
    "
