# RPi-exclusive layers: meta-raspberrypi base, our extensions, the
# upstream Mender layers, and meta-lts-mixins for a backported U-Boot.
#
# meta-lts-mixins ships u-boot_2025.04.bb which wins over
# poky-scarthgap's u-boot_2024.01.bb by version selection. We need 2025.04
# for two reasons:
#   - RPi5 (BCM2712) is unsupported in poky's u-boot_2024.01.bb.
#   - meta-mender-raspberrypi's U-Boot patches are authored against
#     2025.04 defconfigs and fail to apply on 2024.01.
# This mirrors upstream meta-mender-community/kas/include/raspberrypi.yml
# which pulls meta-lts-mixins for every RPi target (rpi0..rpi5).
#
# Mender artifact emission is gated per-machine: RPi3 sets
# IMAGE_FSTYPES:remove = "... mender ..." in its machine conf (MBR boot
# is incompatible with Mender's mender-image-sd default), so parsing the
# Mender recipes is a harmless no-op for RPi3 builds (u-boot likewise
# parses but doesn't compile because upstream meta-raspberrypi defaults
# RPI_USE_U_BOOT to "0" when no machine conf opts in).

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-raspberrypi \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-rpi-extensions \
    ${TOPDIR}/../repos/meta-mender/meta-mender-core \
    ${TOPDIR}/../repos/meta-mender-community/meta-mender-raspberrypi \
    ${TOPDIR}/../repos/meta-lts-mixins \
    "
