FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:class-target = " ${@'file://usg-notice-sshd.conf' if d.getVar('WENDYOS_USG_NOTICE') == '1' else ''}"
RDEPENDS:${PN}-sshd:append:class-target = " ${@'wendyos-access-notice' if d.getVar('WENDYOS_USG_NOTICE') == '1' else ''}"

do_install:append:class-target() {
    if [ "${WENDYOS_USG_NOTICE}" = "1" ]; then
        test -f ${D}${sysconfdir}/pam.d/sshd || bbfatal "USG notice requires PAM OpenSSH"
        # The public key is mandatory before this consent-only PAM auth step.
        # Retain all upstream account, password-change and session checks.
        {
            printf 'auth requisite pam_wendy_notice.so\naccount requisite pam_wendy_notice.so\n'
            sed '/^[[:space:]]*auth[[:space:]]/d' ${D}${sysconfdir}/pam.d/sshd
        } > ${D}${sysconfdir}/pam.d/sshd.notice
        mv ${D}${sysconfdir}/pam.d/sshd.notice ${D}${sysconfdir}/pam.d/sshd
        # OpenSSH uses the first global value; prepend before existing includes.
        for config in sshd_config sshd_config_readonly; do
            cat ${UNPACKDIR}/usg-notice-sshd.conf ${D}${sysconfdir}/ssh/$config > ${D}${sysconfdir}/ssh/$config.notice
            chmod 0600 ${D}${sysconfdir}/ssh/$config.notice
            mv ${D}${sysconfdir}/ssh/$config.notice ${D}${sysconfdir}/ssh/$config
        done
    fi
}
