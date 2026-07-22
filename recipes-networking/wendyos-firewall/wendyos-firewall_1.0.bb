SUMMARY = "WendyOS host firewall (default-deny nftables INPUT ruleset)"
DESCRIPTION = "Finding H3 of the 2026-07 security hardening audit. Installs a \
conservative default-deny INPUT nftables ruleset plus a systemd oneshot that \
applies it at boot. INPUT is default-deny with an explicit allow-list \
(loopback, established/related, ICMP/ICMPv6, DHCP client, mDNS, the wendy-agent \
port, and the usb0/cni0 trusted interfaces); OUTPUT and FORWARD stay permissive \
so container (CNI bridge + masquerade) networking keeps working."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://wendyos-firewall.nft \
    file://wendyos-firewall.service \
    "

S = "${UNPACKDIR}"

inherit systemd

# nftables provides the nft binary the service invokes at boot.
RDEPENDS:${PN} = "nftables"

do_install() {
    # Ruleset lives under /etc/nftables.d/ (name matches *.nft so tooling and
    # the security guardrail pick it up). Applied by our systemd oneshot.
    install -d ${D}${sysconfdir}/nftables.d
    install -m 0644 ${UNPACKDIR}/wendyos-firewall.nft \
        ${D}${sysconfdir}/nftables.d/wendyos-firewall.nft

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-firewall.service \
        ${D}${systemd_system_unitdir}/wendyos-firewall.service
}

FILES:${PN} = " \
    ${sysconfdir}/nftables.d/wendyos-firewall.nft \
    ${systemd_system_unitdir}/wendyos-firewall.service \
    "

SYSTEMD_SERVICE:${PN} = "wendyos-firewall.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
