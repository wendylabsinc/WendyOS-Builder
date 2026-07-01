# Base Tegra layer set shared by every Tegra board (formerly
# tegra-thor.inc). Used directly by Thor (tegra264) and JP7/wrynose Orin
# boards — JP7 has no meta-mender-tegra; OTA on those boards arrives with
# wendyos-update (docs/plans/wendy-ota-update.md).
#
# tegra.inc 'require's this file and layers the meta-mender* paths on top
# for tegra234 JP6 (Orin/scarthgap) builds, so the meta-tegra /
# meta-tegra-community / meta-tegra-extensions paths live in exactly one
# place.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-tegra \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-tegra-community \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-tegra-extensions \
    "
