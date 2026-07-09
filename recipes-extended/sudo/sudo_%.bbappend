FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Passwordless sudo for the wendy user, fleet-wide. Shipped here (in the sudo
# recipe) rather than in wendyos-user because sudo-lib owns /etc/sudoers.d — a
# single package owning the dir + file avoids the rpm dir-ownership conflict
# that co-owning it from wendyos-user triggers. Build-time file (was a
# pkg_postinst_ontarget) so it is present immediately, survives a read-only
# rootfs, and is inspectable.
SRC_URI:append = " file://wendyos-sudoers"

do_install:append() {
    install -d ${D}${sysconfdir}/sudoers.d
    install -m 0440 ${UNPACKDIR}/wendyos-sudoers ${D}${sysconfdir}/sudoers.d/wendy
}

FILES:${PN}-lib:append = " ${sysconfdir}/sudoers.d/wendy"

