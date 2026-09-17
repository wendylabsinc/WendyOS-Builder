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

# LAYERSERIES_COMPAT guard for meta-qcom, which declares "wrynose" at the pinned
# SRCREV_QCOM. That already intersects oe-core's LAYERSERIES_CORENAMES ("wrynose
# blacksail"), so this is normally redundant -- it covers the pin being moved to
# a commit that declares neither. Same situation, and same reason it MUST live in
# a bblayers include rather than local.conf, as meta-raspberrypi: see the
# cookerdata.py note in bblayers/rpi-blacksail.inc.
LAYERSERIES_COMPAT_qcom:append = " blacksail"
