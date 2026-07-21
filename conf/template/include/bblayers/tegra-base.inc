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

# TPM 2.0 stack (fTPM over OP-TEE) for /data encryption, mirroring bblayers/x86.inc.
# meta-tpm provides libtss2 (needed by systemd's tpm2 PACKAGECONFIG) plus tpm2-tools/
# tss. Always layered here -- a BBLAYERS add cannot read WENDYOS_ENABLE_TPM (set at
# local.conf time, after this include is parsed), so the TPM functionality is gated
# elsewhere (DISTRO_FEATURES, systemd PACKAGECONFIG, IMAGE_INSTALL). Harmless when
# off, aside from a benign "tpm2 not in DISTRO_FEATURES" parse warning on TPM-off
# builds (same as x86).
BBLAYERS += " ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-security/meta-tpm "

# blacksail gate bridge: meta-tpm declares LAYERSERIES_COMPAT_tpm-layer="wrynose";
# make blacksail explicit. Must live in a bblayers include (LAYERSERIES_COMPAT is
# checked during the layer.conf loop, before local.conf postfiles). Inert off the
# blacksail tree.
LAYERSERIES_COMPAT_tpm-layer:append = "${@' blacksail' if d.getVar('WENDYOS_LAYER_TREE') == 'blacksail' else ''}"
