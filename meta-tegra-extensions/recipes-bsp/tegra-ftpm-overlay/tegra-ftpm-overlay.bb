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

# Per-SoC overlay source. Only tegra264 (Thor) is validated + shipped today.
# To add Orin (tegra234):
#   - drop a validated tegra234-ftpm.dtso in files/ (from NVIDIA's t23x-public-dts),
#   - set FTPM_DTSO:tegra234 and add it to SRC_URI below,
#   - AND flip OPTEE_ENABLE_FTPM:tegra234 = "1" (tegra234's OP-TEE does not build the
#     fTPM TA by default, unlike tegra264 -- that is an OP-TEE rebuild, so validate
#     the TA comes up before enabling),
#   - then map WENDYOS_FTPM_DTBO:tegra234 in tegra-image.inc.
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
            "no fTPM overlay for MACHINE '%s' (this SoC has no validated fTPM DT overlay yet)"
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
