SUMMARY = "WendyOS host firewall (nftables default-deny inbound)"
DESCRIPTION = "Ships an isolated nftables ruleset (table inet wendy_filter) that \
default-denies inbound traffic on the host input hook while leaving containerd/CNI's \
forward/nat chains untouched. Finding H3. Ships in LOG/AUDIT mode (policy accept + \
drop-logging); enforce mode and build-time interface parameterization are the \
documented follow-up (docs/security/specs/H3-host-firewall-design.md). \
NOTE: authored as a draft — needs a Yocto build + on-hardware reachability check \
before enforce mode is enabled."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://wendyos-firewall.nft \
    file://wendyos-firewall.service \
    "
S = "${UNPACKDIR}"

inherit systemd

do_install() {
    install -d ${D}${sysconfdir}/nftables
    install -m 0644 ${UNPACKDIR}/wendyos-firewall.nft ${D}${sysconfdir}/nftables/wendyos-firewall.nft

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-firewall.service ${D}${systemd_system_unitdir}/wendyos-firewall.service
}

SYSTEMD_SERVICE:${PN} = "wendyos-firewall.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = "nftables"
# A monolithic kernel may build these =y; recommend (not require) the modules.
RRECOMMENDS:${PN} += " \
    kernel-module-nf-tables \
    kernel-module-nft-compat \
    kernel-module-nft-log \
    kernel-module-nft-counter \
    "

FILES:${PN} += " \
    ${sysconfdir}/nftables/wendyos-firewall.nft \
    ${systemd_system_unitdir}/wendyos-firewall.service \
    "
