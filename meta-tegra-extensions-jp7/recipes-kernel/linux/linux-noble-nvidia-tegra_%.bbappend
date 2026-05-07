
# TODO: re-derive usb-gadget.cfg + usb-gadget-builtin.cfg from a 6.8
# menuconfig — Kconfig surface changed between 5.15 and 6.8 (configfs
# paths, CONFIG_USB_F_* symbol set, role-switch sysfs layout).
# The fragments below are starting-point copies of the linux-jammy
# (5.15) versions and have NOT been validated against linux-noble (6.8).
# After the first Thor build boots, run a 6.8 menuconfig with the
# fragments applied, confirm tegra-xudc + g_ncm configfs paths are
# exposed, and update both .cfg files.

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# Note: the jammy bbappend (5.15) currently
# only references usb-gadget.cfg even though the dir ships
# usb-gadget-builtin.cfg too — that asymmetry is intentional in the 5.15
# kernel (jammy menuconfig already has the configfs/ncm paths built-in
# enough that the .m fragment alone suffices). For 6.8 the builtin
# fragment may or may not be redundant — re-derive both during the
# menuconfig pass and prune whichever is unnecessary.
SRC_URI += " \
    file://usb-gadget.cfg \
    file://usb-gadget-builtin.cfg \
    "
