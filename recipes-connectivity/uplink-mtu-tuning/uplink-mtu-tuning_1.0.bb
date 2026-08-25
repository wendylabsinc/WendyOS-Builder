SUMMARY = "Uplink MTU tuning for PMTU-black-holed paths"
DESCRIPTION = "Lowers the uplink MTU when the path MTU is smaller than the link \
MTU and the carrier drops the ICMP that would say so. Detects the condition from \
any host TCP socket the kernel has already clamped via RFC 4821 probing, applies \
the change at runtime only, and restores it when the network changes. Does \
nothing on a healthy uplink."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Deliberately in the tree but NOT in any packagegroup or image: this is not
# dead code, and it is not something to re-add casually either.
# The primary fix lives on the LTE modem (MikroTik KNOT, RouterOS): an MSS
# clamp in the firewall mangle plus DHCP option 26. That covers the same gaps
# better - deterministically at connection setup instead of ~20s after boot,
# and it also reaches container inbound traffic, which this recipe cannot: a
# container advertises its MSS from its own 1500-byte veth and never sees the
# host uplink MTU.
# Keep this recipe as the escalation path for a site where the modem cannot be
# configured. To enable it, add uplink-mtu-tuning to an image's IMAGE_INSTALL
# or to packagegroup-wendyos-base. Doing so is also what puts ss(8) back in the
# image (see RDEPENDS below): outside a WENDYOS_DEBUG build, "ss -tin" is the
# only way to read a socket's mss, pmtu and advmss, i.e. to confirm the
# black hole or a modem-side MSS clamp on a production device.

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://uplink-mtu-tuning.sh \
    file://uplink-mtu-tuning.service \
    file://uplink-mtu-tuning.timer \
    "
S = "${UNPACKDIR}"

# Only the timer is enabled: it pulls in the service on each tick. Enabling the
# oneshot service as well would additionally run it once at boot, before the
# agent has a connection to look at.
SYSTEMD_SERVICE:${PN} = "uplink-mtu-tuning.timer"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/uplink-mtu-tuning.service ${D}${systemd_system_unitdir}/uplink-mtu-tuning.service
    install -m 0644 ${UNPACKDIR}/uplink-mtu-tuning.timer ${D}${systemd_system_unitdir}/uplink-mtu-tuning.timer

    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/uplink-mtu-tuning.sh ${D}${bindir}/uplink-mtu-tuning.sh
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/uplink-mtu-tuning.service \
    ${systemd_system_unitdir}/uplink-mtu-tuning.timer \
    ${bindir}/uplink-mtu-tuning.sh \
    "

# ss for the socket table, ip for the default route, nmcli to apply the MTU.
# awk comes from busybox (packagegroup-core-boot). Note iproute2-ss is otherwise
# only pulled in by packagegroup-wendyos-debug, so this adds it to release images.
RDEPENDS:${PN} = " \
    systemd \
    iproute2-ss \
    iproute2-ip \
    networkmanager-nmcli \
    "

