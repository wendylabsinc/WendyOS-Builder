# Base Tegra layer set shared by every Tegra board (formerly
# tegra-thor.inc). Used by Thor (tegra264) and the Orin boards; OTA on those
# boards is delivered by wendyos-update (docs/plans/wendy-ota-update.md).
# It gathers the meta-tegra / meta-tegra-community / meta-tegra-extensions
# paths in exactly one place.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-tegra \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-tegra-community \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-tegra-extensions \
    "
