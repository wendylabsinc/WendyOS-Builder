SUMMARY = "WendyOS GPU container-compute setup (detect, on-demand load, CDI)"
DESCRIPTION = "At boot, detects the GPU vendor(s) present, loads the matching \
kernel modules on demand, and generates the container CDI spec. The NVIDIA \
(CUDA) path is implemented. The AMD (ROCm) path is a Phase C stub. Part of the \
single-image GPU strategy for the x86 fleet."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://wendyos-gpu-cdi.sh \
    file://wendyos-gpu-cdi.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "wendyos-gpu-cdi.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/wendyos-gpu-cdi.sh ${D}${bindir}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-gpu-cdi.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    ${bindir}/wendyos-gpu-cdi.sh \
    ${systemd_system_unitdir}/wendyos-gpu-cdi.service \
    "
