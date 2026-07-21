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

# TPM 2.0 stack for /data encryption.
# Layered only here, so it never reaches other boards. Clone meta-security next to
# The TPM functionality is gated separately by WENDYOS_ENABLE_TPM (kernel cfg, systemd
# PACKAGECONFIG, image install — see x86.inc), which cannot gate a BBLAYERS add
# because it is set at local.conf time, after this bblayers include is parsed.
BBLAYERS += " ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-security/meta-tpm "

# blacksail gate bridge. meta-tpm declares LAYERSERIES_COMPAT_tpm-layer="wrynose".
# On the blacksail tree the core still intersects "wrynose" (same as meta-oe), so it
# parses; this append makes blacksail explicit and covers a core that later drops
# wrynose. It MUST live in a bblayers include: LAYERSERIES_COMPAT is snapshotted and
# checked during the layer.conf loop, before local.conf postfiles like
# blacksail-compat.inc (see the NOTE there). Inert off the blacksail tree.
LAYERSERIES_COMPAT_tpm-layer:append = "${@' blacksail' if d.getVar('WENDYOS_LAYER_TREE') == 'blacksail' else ''}"
