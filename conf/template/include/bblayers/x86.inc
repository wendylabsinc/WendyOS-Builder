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

# TPM 2.0 stack for /data encryption. meta-tpm provides libtss2 (needed by
# systemd's tpm2 PACKAGECONFIG) plus tpm2-tools/tss. bootstrap.sh clones
# meta-security for every board from the pin in scripts/upstream-repos.env;
# the Tegra boards layer the same path from bblayers/tegra-base.inc.
# The TPM functionality is gated separately by WENDYOS_ENABLE_TPM (kernel cfg,
# systemd PACKAGECONFIG, image install — see local/x86.inc), which cannot gate a
# BBLAYERS add because it is set at local.conf time, after this bblayers include
# is parsed.
BBLAYERS += " ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-security/meta-tpm "
