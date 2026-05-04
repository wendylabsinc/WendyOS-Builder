# OpenEmbedded and poky layers shared by every board.
#
# Paths under repos/${WENDYOS_LAYER_TREE}/ resolve to the per-series layer
# tree populated by bootstrap.sh. The "poky" monolith is composed at clone
# time from three split-style upstream repos: openembedded-core (provides
# meta), meta-yocto (provides meta-poky), and bitbake (sourced via
# oe-init-build-env, not added to BBLAYERS).

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-openembedded/meta-filesystems \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-openembedded/meta-multimedia \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-openembedded/meta-networking \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-openembedded/meta-oe \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-openembedded/meta-python \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-virtualization \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/openembedded-core/meta \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-yocto/meta-poky \
    "
