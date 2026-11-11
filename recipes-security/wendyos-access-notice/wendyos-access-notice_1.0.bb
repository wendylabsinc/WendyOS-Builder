SUMMARY = "Explicit US Government access notice and consent"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit features_check
REQUIRED_DISTRO_FEATURES = "pam"
DEPENDS = "libpam"
SRC_URI = "file://pam_wendy_notice.c file://usg-notice"
S = "${UNPACKDIR}"

do_compile() {
    ${CC} ${CFLAGS} ${CPPFLAGS} -fPIC -shared -Wall -Wextra -Werror \
        -DNOTICE_FILE='"${datadir}/wendyos-access-notice/usg-notice"' \
        ${S}/pam_wendy_notice.c ${LDFLAGS} -lpam -o pam_wendy_notice.so
}

do_install() {
    install -d ${D}${base_libdir}/security ${D}${datadir}/wendyos-access-notice
    install -m 0755 pam_wendy_notice.so ${D}${base_libdir}/security/
    install -m 0644 ${S}/usg-notice ${D}${datadir}/wendyos-access-notice/
}

FILES:${PN} = "${base_libdir}/security/pam_wendy_notice.so ${datadir}/wendyos-access-notice"
