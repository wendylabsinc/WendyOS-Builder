# Tegra-exclusive layers: Mender OTA stack, meta-tegra, Tegra sub-layer.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-mender/meta-mender-core \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-mender-community/meta-mender-tegra/meta-mender-tegra-common \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-mender-community/meta-mender-tegra/meta-mender-tegra-jetpack6 \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-tegra \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-tegra-community \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-tegra-extensions \
    "
