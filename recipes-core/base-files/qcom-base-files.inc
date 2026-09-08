# Qualcomm Dragonwing base-files extensions.
# Included conditionally from base-files_%.bbappend — safe for other machines.

SRC_URI:append = " \
    file://qcom-wendy-fstab \
    "

# Dragonwing uses the wendyos-update A/B layout (two rootfs slots), so the stock
# oe-core fstab is wrong twice over: it carries a "/" entry (the slot device
# varies) and no /boot entry (the grubenv connector needs the ESP mounted). Install
# the A/B fstab instead — no "/", everything by LABEL.
#
# Installed unconditionally for this board rather than gated on WENDYOS_OTA: the
# entries are all `nofail`, so the file is also correct during bring-up when the
# config and data partitions do not exist yet.
do_install:append() {
    install -m 0644 ${UNPACKDIR}/qcom-wendy-fstab ${D}${sysconfdir}/fstab
}
