SUMMARY = "WendyOS Device Identity Management"
DESCRIPTION = "Generates and manages unique device UUID and device name for WendyOS devices"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

# Storage medium ("nvme"/"emmc"/"sd") for /etc/wendyos/device-type; set per
# board in the template local.conf. Weak default keeps ${STORAGE} well-defined
# (empty) for boards that declare no medium (e.g. qemu), so the do_install
# guard below reliably skips the STORAGE line instead of risking a literal.
STORAGE ??= ""

SRC_URI = " \
    file://generate-uuid.sh \
    file://generate-device-name.sh \
    file://update-mdns-uuid.sh \
    file://wendyos-uuid-generate.service \
    file://wendyos-device-name-generate.service \
    file://wendyos-identity.service \
    file://adjectives.txt \
    file://nouns.txt \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "wendyos-uuid-generate.service wendyos-device-name-generate.service wendyos-identity.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Install scripts to /usr/bin
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/generate-uuid.sh ${D}${bindir}/
    install -m 0755 ${UNPACKDIR}/generate-device-name.sh ${D}${bindir}/
    install -m 0755 ${UNPACKDIR}/update-mdns-uuid.sh ${D}${bindir}/

    # Install word lists for device name generation
    install -d ${D}${datadir}/wendyos
    install -m 0644 ${UNPACKDIR}/adjectives.txt ${D}${datadir}/wendyos/
    install -m 0644 ${UNPACKDIR}/nouns.txt ${D}${datadir}/wendyos/

    # Install systemd services
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-uuid-generate.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/wendyos-device-name-generate.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/wendyos-identity.service ${D}${systemd_system_unitdir}/

    # Create directory for identity storage
    install -d ${D}${sysconfdir}/wendyos

    # Authoritative version.txt on the read-only rootfs (never shadowed by
    # the /etc/wendyos bind mount on Tegra).
    install -d ${D}${nonarch_libdir}/wendyos
    echo "WendyOS-${DISTRO_VERSION}" > ${WORKDIR}/version.txt
    install -m 0644 ${WORKDIR}/version.txt ${D}${nonarch_libdir}/wendyos/version.txt

    # Consumer-facing path: symlink on rootfs so /etc/wendyos/version.txt
    # resolves on non-Tegra. On Tegra the bind mount shadows this symlink;
    # setup-etc-binds.sh writes a real file at /etc/wendyos/version.txt
    # (via the /data bind mount) on every boot to stay OTA-fresh.
    ln -sf ../../usr/lib/wendyos/version.txt ${D}${sysconfdir}/wendyos/version.txt

    # Create build ID file (actual date will be set at first boot if needed)
    echo "WendyOS-${DISTRO_VERSION}" > ${WORKDIR}/wendyos-build-id
    install -m 0644 ${WORKDIR}/wendyos-build-id ${D}${sysconfdir}/wendyos-build-id
}

do_install:append() {
    # Stable board identity for the wendy agent. Sourced as shell.
    # BOARD is set in conf/machine/<machine>.conf; MACHINE is the yocto machine
    # name; STORAGE ("nvme"/"emmc"/"sd") is set in the board template local.conf.
    install -d ${D}${sysconfdir}/wendyos
    printf 'BOARD=%s\n'   "${WENDYOS_BOARD_ID}" >  ${D}${sysconfdir}/wendyos/device-type
    printf 'MACHINE=%s\n' "${MACHINE}"          >> ${D}${sysconfdir}/wendyos/device-type
    # STORAGE lets the OTA client pick the storage-specific artifact directly
    # (e.g. jetson-agx-orin publishes both an NVMe and an eMMC image under one
    # manifest key). Without it the agent must infer the medium from the MACHINE
    # name, which fails for legacy/plain-string identities and can serve the
    # wrong image. Only emitted when the board declares a medium.
    if [ -n "${STORAGE}" ]; then
        printf 'STORAGE=%s\n' "${STORAGE}"      >> ${D}${sysconfdir}/wendyos/device-type
    fi
    chmod 0644 ${D}${sysconfdir}/wendyos/device-type
}

FILES:${PN} += "${bindir}/generate-uuid.sh"
FILES:${PN} += "${bindir}/generate-device-name.sh"
FILES:${PN} += "${bindir}/update-mdns-uuid.sh"
FILES:${PN} += "${datadir}/wendyos/adjectives.txt"
FILES:${PN} += "${datadir}/wendyos/nouns.txt"
FILES:${PN} += "${systemd_system_unitdir}/wendyos-uuid-generate.service"
FILES:${PN} += "${systemd_system_unitdir}/wendyos-device-name-generate.service"
FILES:${PN} += "${systemd_system_unitdir}/wendyos-identity.service"
FILES:${PN} += "${sysconfdir}/wendyos"
FILES:${PN} += "${sysconfdir}/wendyos/device-type"
FILES:${PN} += "${sysconfdir}/wendyos/version.txt"
FILES:${PN} += "${nonarch_libdir}/wendyos/version.txt"
FILES:${PN} += "${sysconfdir}/wendyos-build-id"

CONFFILES:${PN} += "${sysconfdir}/wendyos/device-type"

RDEPENDS:${PN} = "bash util-linux-uuidgen avahi-daemon coreutils iproute2"