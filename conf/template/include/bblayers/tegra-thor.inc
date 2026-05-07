# Tegra layer set without the Mender OTA stack. Used by Thor (tegra264)
# Mender on Thor is deferred until upstream readiness clears
#
# tegra.inc 'require's this file and layers the meta-mender* paths on top
# for tegra234 (Orin) builds, so the meta-tegra / meta-tegra-community /
# meta-tegra-extensions paths live in exactly one place.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-tegra \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-tegra-community \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-tegra-extensions \
    "
