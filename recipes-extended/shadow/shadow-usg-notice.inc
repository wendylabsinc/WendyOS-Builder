RDEPENDS:${PN}-base:append:class-target = " ${@'wendyos-access-notice' if d.getVar('WENDYOS_USG_NOTICE') == '1' else ''}"

do_install:append:class-target() {
    if [ "${WENDYOS_USG_NOTICE}" = "1" ]; then
        test -f ${D}${sysconfdir}/pam.d/login || bbfatal "USG notice requires PAM login"
        for type in auth account session; do
            grep -Eq "^[[:space:]]*$type[[:space:]]+" ${D}${sysconfdir}/pam.d/login || bbfatal "USG notice requires upstream login $type checks"
        done
        {
            printf 'auth requisite pam_wendy_notice.so\naccount requisite pam_wendy_notice.so\n'
            cat ${D}${sysconfdir}/pam.d/login
        } > ${D}${sysconfdir}/pam.d/login.notice
        mv ${D}${sysconfdir}/pam.d/login.notice ${D}${sysconfdir}/pam.d/login
    fi
}
