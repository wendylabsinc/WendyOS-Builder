# RPi-exclusive layers: meta-raspberrypi base, our extensions, and
# meta-lts-mixins for a backported U-Boot.
#
# scarthgap-stock U-Boot has no BCM2712 (RPi5) support. meta-lts-mixins
# ships u-boot_2025.04.bb which wins over poky-scarthgap's 2024.01.bb
# by version selection — its scarthgap/u-boot branch is what
# meta-mender-community's kas integration pulls for every RPi target.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-raspberrypi \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-rpi-extensions \
    ${TOPDIR}/../repos/meta-lts-mixins \
    "
