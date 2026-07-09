# Generic x86_64 PC layer set.
#
# meta-yocto-bsp provides the upstream genericx86-64 reference BSP. WendyOS
# adds a wrapper machine config so the same BSP can carry Wendy-specific
# defaults without forking the upstream machine metadata. meta-x86-extensions
# carries the x86-only recipes/bbappends (drivers, installer, kernel modules)
# and is layered only here, so it never reaches other boards.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-yocto/meta-yocto-bsp \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-x86-extensions \
    "
