# Qualcomm layer set (Dragonwing / QCS SoCs), used by the dragonwing-* boards.
#
# meta-qcom alone: its LAYERDEPENDS is just "core", and the layers it only
# RECOMMENDS (openembedded-layer, meta-arm) are either already present via
# bblayers/oe-common.inc or needed only by the *-open-fw machine variants,
# which add TF-A + OP-TEE and are not what we build.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-qcom \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-qcom-extensions \
    "
