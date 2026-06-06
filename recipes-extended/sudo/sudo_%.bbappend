FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://wendyos-sudoers"

do_install:append() {
    install -d ${D}${sysconfdir}/sudoers.d
    install -m 0440 ${UNPACKDIR}/wendyos-sudoers ${D}${sysconfdir}/sudoers.d/wendy
}

FILES:${PN}-lib:append = " ${sysconfdir}/sudoers.d/wendy"
