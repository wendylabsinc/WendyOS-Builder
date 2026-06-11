# Tegra-exclusive layers: Mender OTA stack, meta-tegra, Tegra sub-layer.
# The shared meta-tegra paths are factored into tegra-base.inc so Thor
# (tegra264) and JP7 Orin boards (no Mender on wrynose) can reuse them
# without duplication.

require ${TOPDIR}/../${WENDYOS_META_REPO}/conf/template/include/bblayers/tegra-base.inc

BBLAYERS += " \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-tegra-extensions-jp6 \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-mender/meta-mender-core \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-mender-community/meta-mender-tegra/meta-mender-tegra-common \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-mender-community/meta-mender-tegra/meta-mender-tegra-jetpack6 \
    "
