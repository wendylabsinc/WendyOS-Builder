SUMMARY = "Containerd global memory limit configuration"
DESCRIPTION = "Configures containerd with a global 7.4GB memory limit for ALL containers combined to prevent device lockup"

inherit systemd
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "\
    file://containerd-memory-limit.conf \
    file://containerd-requires-data-mount.conf \
    file://README-memory-limits.md \
"
S = "${UNPACKDIR}"

do_install() {
    # Install systemd drop-in to limit total containerd memory
    install -d ${D}${systemd_system_unitdir}/containerd.service.d
    install -m 0644 ${UNPACKDIR}/containerd-memory-limit.conf ${D}${systemd_system_unitdir}/containerd.service.d/memory-limit.conf

    # Install systemd drop-in requiring the /var/lib/containerd bind mount
    # before containerd starts (WDY-3127)
    install -m 0644 ${UNPACKDIR}/containerd-requires-data-mount.conf ${D}${systemd_system_unitdir}/containerd.service.d/requires-data-mount.conf

    install -d ${D}${docdir}/${PN}
    install -m 0644 ${UNPACKDIR}/README-memory-limits.md ${D}${docdir}/${PN}/README-memory-limits.md
}

FILES:${PN} += "\
    ${systemd_system_unitdir}/containerd.service.d/memory-limit.conf \
    ${systemd_system_unitdir}/containerd.service.d/requires-data-mount.conf \
    ${docdir}/${PN}/README-memory-limits.md \
"

# Note: No RDEPENDS needed - this just provides config files
# containerd-opencontainers is pulled in by packagegroup-wendyos-container.
