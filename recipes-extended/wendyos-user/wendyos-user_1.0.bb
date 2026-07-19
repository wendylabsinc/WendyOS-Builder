SUMMARY = "WendyOS Default User Configuration"
DESCRIPTION = "Creates the default 'wendy' user with appropriate permissions for WendyOS. \
The base package creates the user and sudoers config. The -data-setup package \
provides the first-boot service that initializes the home directory on the \
persistent /data partition (Tegra only)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit useradd systemd

SRC_URI = " \
    file://wendyos-user-setup.sh \
    file://wendyos-user-setup.service \
"
S = "${UNPACKDIR}"

PACKAGES = "${PN}-data-setup ${PN}"

# Create wendy user - simplified group list (non-existent groups cause failures)
USERADD_PACKAGES = "${PN}"
# No password is baked in (finding H2): useradd without -p leaves the account
# password locked, so there is no fleet-wide shared credential. Device access is
# gRPC-only with no interactive login, so the wendy account never needs one.
# useradd -m creates /home/wendy on the rootfs; on Tegra, the first-boot service
# in wendyos-user-data-setup re-initializes it from persistent storage (/data/home)
USERADD_PARAM:${PN} = "-m -d /home/wendy -s /bin/bash -G dialout,video,audio,users wendy"

SYSTEMD_SERVICE:${PN}-data-setup = "wendyos-user-setup.service"
SYSTEMD_AUTO_ENABLE:${PN}-data-setup = "enable"

do_install() {
    # Install first-boot setup script (packaged in -data-setup)
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-user-setup.sh ${D}${sbindir}/wendyos-user-setup.sh

    # Install systemd service (packaged in -data-setup)
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-user-setup.service ${D}${systemd_system_unitdir}/wendyos-user-setup.service
}

pkg_postinst_ontarget:${PN}() {
    # The wendy user is an unprivileged interactive identity — no sudo (finding
    # H2). Device management is gRPC-only via wendy-agent, which runs as root;
    # no on-device unit or script escalates through this user. Actively scrub any
    # stale passwordless-sudo grant written by an image built before this change
    # so an A/B OTA upgrade drops it too (harmless if the file is absent).
    rm -f /etc/sudoers.d/wendy
}

# Base package: user creation only (no files, useradd class handles /etc/passwd).
# sudo is intentionally NOT pulled in — the wendy user has no sudo (H2); a dev
# break-glass path, if ever needed, belongs in a dev-image opt-in, not the fleet.
FILES:${PN} = ""
ALLOW_EMPTY:${PN} = "1"
RDEPENDS:${PN} = "bash systemd"

# Data setup package: first-boot /data/home initialization (Tegra only)
SUMMARY:${PN}-data-setup = "WendyOS User Home Directory Setup for /data Partition"
FILES:${PN}-data-setup = " \
    ${sbindir}/wendyos-user-setup.sh \
    ${systemd_system_unitdir}/wendyos-user-setup.service \
"
RDEPENDS:${PN}-data-setup = "${PN} bash systemd-mount-home"
