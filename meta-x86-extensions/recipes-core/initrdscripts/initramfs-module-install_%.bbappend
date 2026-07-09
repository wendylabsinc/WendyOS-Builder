FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:x86-wendyos = " \
    file://wendyos-install-wifi.sh \
    file://wendyos-install-drivers.sh \
    "

do_install:append:x86-wendyos() {
    install -m 0755 ${UNPACKDIR}/wendyos-install-wifi.sh ${D}/init.d/wendyos-install-wifi.sh
    install -m 0755 ${UNPACKDIR}/wendyos-install-drivers.sh ${D}/init.d/wendyos-install-drivers.sh

    sed -i '/^if \[ -d \/tgt_root\/etc\/ \] ; then/i\
if [ -x /init.d/wendyos-install-wifi.sh ]; then\
    /init.d/wendyos-install-wifi.sh /tgt_root\
fi\
if [ -x /init.d/wendyos-install-drivers.sh ]; then\
    /init.d/wendyos-install-drivers.sh /tgt_root\
fi\
' ${D}/init.d/install.sh
}

FILES:${PN}:append:x86-wendyos = " \
    /init.d/wendyos-install-wifi.sh \
    /init.d/wendyos-install-drivers.sh \
    "
