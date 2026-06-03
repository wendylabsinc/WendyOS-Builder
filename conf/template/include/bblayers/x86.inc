# Generic x86_64 PC layer set.
#
# meta-yocto-bsp provides the upstream genericx86-64 reference BSP. WendyOS
# adds a wrapper machine config so the same BSP can carry Wendy-specific
# defaults without forking the upstream machine metadata.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-yocto/meta-yocto-bsp \
    "
