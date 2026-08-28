SUMMARY = "Device-tree overlay that enables the fTPM node on NVIDIA Jetson"
DESCRIPTION = "Re-emits NVIDIA's fTPM device-tree overlay with status = \"okay\" \
so the in-tree tpm_ftpm_tee driver binds the microsoft,ftpm node and exposes \
/dev/tpmrm0. The overlay source is selected per SoC via FTPM_DTSO. Actual use is \
gated by WENDYOS_ENABLE_TPM in tegra-image.inc."

# Derived from NVIDIA's GPL-2.0-only t264-public-dts overlay (see the .dtso header).
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Parseable for any Tegra machine; the anonymous python below skips SoCs that have
# no validated overlay (i.e. everything except tegra264 today).
COMPATIBLE_MACHINE = "(tegra)"

# Per-SoC overlay source. Only tegra264 (Thor) needs one: its kernel DTB has no
# firmware/ftpm node at all, so we ship it ourselves with status "okay".
#
# tegra234 (Orin) is DELIBERATELY unmapped -- it needs no overlay. 
# Every t234 board already gets NVIDIA's tegra-optee.dtbo
# (TEGRA_PLUGIN_MANAGER_OVERLAYS in the machine includes), which ships
# firmware/ftpm status "disabled", and the UEFI kernel-DTB fixup
# (EnableFtpmNode, edk2-nvidia DxeDtPlatformDtbKernelLoaderLib) flips it to
# "okay" exactly when the fTPM TA in OP-TEE answers. Enabling TPM on Orin is
# config-only: see the block in conf/template/include/local/tegra-t234.inc.
#
# Map a new SoC here ONLY if its kernel DTB lacks the node AND the UEFI fixup
# cannot arm it (the Thor situation): drop a validated .dtso in files/, set
# FTPM_DTSO:<soc>, and map WENDYOS_FTPM_DTBO:<soc> in
# conf/distro/include/tegra-overlays.inc.
FTPM_DTSO = ""
FTPM_DTSO:tegra264 = "tegra264-ftpm.dtso"
FTPM_DTBO = "${@d.getVar('FTPM_DTSO').replace('.dtso', '.dtbo') if d.getVar('FTPM_DTSO') else ''}"

SRC_URI = "file://tegra264-ftpm.dtso"
S = "${UNPACKDIR}"

DEPENDS += "dtc-native"

# The compiled .dtbo is SoC-specific content, so key sstate on the machine rather
# than inheriting allarch (which would share one artifact across SoCs).
PACKAGE_ARCH = "${MACHINE_ARCH}"

DEPLOYDIR = "${DEPLOY_DIR_IMAGE}"

python () {
    if not d.getVar('FTPM_DTSO'):
        raise bb.parse.SkipRecipe(
            "no fTPM overlay for MACHINE '%s' (only tegra264 needs one; t234 self-arms via UEFI)"
            % d.getVar('MACHINE'))
}

do_compile() {
    ${STAGING_BINDIR_NATIVE}/dtc -I dts -O dtb \
        -o ${B}/${FTPM_DTBO} \
        ${UNPACKDIR}/${FTPM_DTSO}
}

do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 ${B}/${FTPM_DTBO} ${DEPLOYDIR}/
}

addtask deploy after do_compile before do_build

do_install() {
    install -d ${D}${sysconfdir}/tegra/bootcontrol/overlays
    install -m 0644 ${B}/${FTPM_DTBO} \
        ${D}${sysconfdir}/tegra/bootcontrol/overlays/
}

FILES:${PN} += "${sysconfdir}/tegra/bootcontrol/overlays/*.dtbo"

