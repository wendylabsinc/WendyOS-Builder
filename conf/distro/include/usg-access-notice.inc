# Select only for an authorized US Government deployment. This is a notice and
# consent profile, not a complete STIG baseline. See docs/usg-access-notice.md.
WENDYOS_USG_NOTICE = "1"
DISTRO_FEATURES:append = " pam"
PACKAGECONFIG:append:pn-shadow = " pam"
IMAGE_INSTALL:append:pn-wendyos-image = " wendyos-access-notice shadow-base"
INHERIT += "usg-access-notice-check"
