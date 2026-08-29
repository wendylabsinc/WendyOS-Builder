# QEMU/VM base-files extensions.
# Included conditionally from base-files_%.bbappend -- inert on other machines.

SRC_URI:append = " \
    file://vm-fstab \
    "

# Every other board gets its fstab from the OTA stack, which WENDYOS_OTA="none"
# excludes, and qemu-image.inc turns off wic's generated one. Without this the
# VM mounts nothing but "/".
do_install:append() {
    install -m 0644 ${UNPACKDIR}/vm-fstab ${D}${sysconfdir}/fstab
}
