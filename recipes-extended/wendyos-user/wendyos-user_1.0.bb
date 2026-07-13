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
# Finding H2: the wendy account is created LOCKED (no `-p` -> no valid password).
# It formerly shipped a fleet-wide shared password ('wendy') plus passwordless
# sudo — a standing credential that became remote root the moment sshd was
# enabled. Device access is via the wendy-agent (runs as root); interactive
# console access on dev/PR builds is via root (WENDYOS_DEV_LOGIN), not this user.
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

# Finding H2: no sudoers entry. wendy is not in a sudo/wheel group and gets no
# passwordless-root drop-in; it has no elevated privileges by default. If a
# downstream dev build genuinely needs wendy sudo, add a gated
# /etc/sudoers.d/wendy in local.conf — never ship it fleet-wide.

# Base package: user creation only (no files, useradd class handles /etc/passwd)
FILES:${PN} = ""
ALLOW_EMPTY:${PN} = "1"
RDEPENDS:${PN} = "sudo bash systemd"

# Data setup package: first-boot /data/home initialization (Tegra only)
SUMMARY:${PN}-data-setup = "WendyOS User Home Directory Setup for /data Partition"
FILES:${PN}-data-setup = " \
    ${sbindir}/wendyos-user-setup.sh \
    ${systemd_system_unitdir}/wendyos-user-setup.service \
"
RDEPENDS:${PN}-data-setup = "${PN} bash systemd-mount-home"
