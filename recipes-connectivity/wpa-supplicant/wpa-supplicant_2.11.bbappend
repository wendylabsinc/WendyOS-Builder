FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# Full IEEE 802.11 NAN support first shipped in hostap 2.12. Keep the source
# release and its small post-release fix queue explicit until these changes
# are included in a later upstream release.
PV = "2.12"

SRC_URI = "https://w1.fi/releases/wpa_supplicant-${PV}.tar.gz \
           file://wpa-supplicant.sh \
           file://wpa_supplicant.conf \
           file://wpa_supplicant.conf-sane \
           file://99_wpa_supplicant \
           file://0001-PASN-Explicitly-check-Authentication-frame-length.patch \
           file://0002-PASN-Advertise-default-group.patch \
           file://0003-RADIUS-Fix-Message-Authenticator-validation.patch \
           file://0004-NAN-local-lifecycle-cleanup.patch \
           file://0005-control-interface-parent-radio.patch \
           file://0006-NAN-accept-unselected-NDC-in-Request.patch \
           file://wendyos-nan \
           file://wendyos-nan-control.conf \
           "
SRC_URI[sha256sum] = "08e23937e16d0155e55cab2b51f51fbe10d80a1aa91c4e15442645059b737ef6"

LIC_FILES_CHKSUM = "file://COPYING;md5=5ebcb90236d1ad640558c3d3cd3035df \
                    file://README;beginline=1;endline=56;md5=155e35cb3d6ab0d6a17524f48f4e761c \
                    file://wpa_supplicant/wpa_supplicant.c;beginline=1;endline=12;md5=f5ccd57ea91e04800edb88267bf8eae4"

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
