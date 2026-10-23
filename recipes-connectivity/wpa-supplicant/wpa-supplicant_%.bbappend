FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# oe-core ships hostap 2.12, the first release with full IEEE 802.11 NAN
# (Wi-Fi Aware) support. We add its post-release fix queue (three PASN/RADIUS
# backports, plus local NAN lifecycle, parent-radio and NDC fixes) and turn on
# the NAN build options below.
SRC_URI += " \
    file://0001-PASN-Explicitly-check-Authentication-frame-length.patch \
    file://0002-PASN-Advertise-default-group.patch \
    file://0003-RADIUS-Fix-Message-Authenticator-validation.patch \
    file://0004-NAN-local-lifecycle-cleanup.patch \
    file://0005-control-interface-parent-radio.patch \
    file://0006-NAN-accept-unselected-NDC-in-Request.patch \
    file://wendyos-nan \
    file://wendyos-nan-control.conf \
    "

do_configure:append () {
    cat >>wpa_supplicant/.config <<'EOF'

# WendyOS Wi-Fi Aware support
CONFIG_NAN_USD=y
CONFIG_NAN=y
CONFIG_PASN=y
EOF
}

do_install:append () {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-nan ${D}${sbindir}/wendyos-nan

    install -d ${D}${systemd_system_unitdir}/wpa_supplicant.service.d
    install -m 0644 ${UNPACKDIR}/wendyos-nan-control.conf \
        ${D}${systemd_system_unitdir}/wpa_supplicant.service.d/10-wendyos-nan-control.conf
}

RDEPENDS:${PN}:append = " ${PN}-cli util-linux-flock"
FILES:${PN}:append = " ${sbindir}/wendyos-nan ${systemd_system_unitdir}/wpa_supplicant.service.d/10-wendyos-nan-control.conf"
