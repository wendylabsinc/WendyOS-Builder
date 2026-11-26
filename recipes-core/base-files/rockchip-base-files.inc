# Rockchip base-files extensions.
# Included conditionally from base-files_%.bbappend — safe for other machines.

# The A/B table is the Pi 4/5 one, so the Pi's fstab fits as is: /boot, /config
# and /data through their /dev/wendyos links, and no "/" (the boot script sets root=).
SRC_URI:append = " file://rpi-wendy-fstab"

do_install:append() {
    install -m 0644 ${UNPACKDIR}/rpi-wendy-fstab ${D}${sysconfdir}/fstab
}
