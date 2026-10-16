SUMMARY = "Core mesh host networking policy"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch features_check
REQUIRED_DISTRO_FEATURES = "systemd"
# Installed with the agent, independently of whether Internet sharing is enabled.
RDEPENDS:${PN} = "systemd udev"
SRC_URI = "file://90-wendy-mesh.conf file://90-wendy-mesh.rules file://20-mesh-sysctl.conf"
S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${nonarch_libdir}/sysctl.d ${D}${nonarch_base_libdir}/udev/rules.d
    install -d ${D}${systemd_system_unitdir}/wendyos-agent.service.d
    install -m 0644 ${UNPACKDIR}/90-wendy-mesh.conf ${D}${nonarch_libdir}/sysctl.d/
    sed 's|@SYSTEMD_SYSCTL@|${systemd_unitdir}/systemd-sysctl|g' \
        ${UNPACKDIR}/90-wendy-mesh.rules > ${D}${nonarch_base_libdir}/udev/rules.d/90-wendy-mesh.rules
    install -m 0644 ${UNPACKDIR}/20-mesh-sysctl.conf ${D}${systemd_system_unitdir}/wendyos-agent.service.d/
}

FILES:${PN} = "${nonarch_libdir}/sysctl.d/90-wendy-mesh.conf \
    ${nonarch_base_libdir}/udev/rules.d/90-wendy-mesh.rules \
    ${systemd_system_unitdir}/wendyos-agent.service.d/20-mesh-sysctl.conf"
