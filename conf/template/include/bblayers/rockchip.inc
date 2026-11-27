# Rockchip layer set. meta-arm (and its meta-arm-toolchain) is only there for
# meta-rockchip's layer dependency: TF-A and DDR init come from rkbin blobs.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-arm/meta-arm-toolchain \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-arm/meta-arm \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-rockchip \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-rockchip-extensions \
    "
