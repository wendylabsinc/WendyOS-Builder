SUMMARY = "WendyOS NVIDIA dGPU CDI helper"
DESCRIPTION = "Generates NVIDIA CDI metadata on x86 PCs when NVIDIA driver support is present"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://generate-nvidia-cdi.sh \
    file://wendyos-nvidia-cdi.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "wendyos-nvidia-cdi.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/generate-nvidia-cdi.sh ${D}${bindir}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-nvidia-cdi.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    ${bindir}/generate-nvidia-cdi.sh \
    ${systemd_system_unitdir}/wendyos-nvidia-cdi.service \
    "
