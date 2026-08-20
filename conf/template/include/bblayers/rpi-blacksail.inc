# RPi layers for the blacksail tree (WENDYOS_LAYER_TREE = "blacksail"), used by
# the rpi3-sd / rpi4-sd / rpi5-sd / rpi5-nvme board templates. Uses the wendy OTA
# stack: meta-rpi-extensions supplies the A/B boot.cmd via its
# rpi-u-boot-scr.bbappend.
#
# Nothing is layered beyond meta-raspberrypi and meta-rpi-extensions. Both Go
# 1.26 (needed by wendyos-update's go.mod) and U-Boot 2026.04 are native to
# blacksail oe-core, so no backport layer is cloned or layered. 2026.04 boots the
# Pi 5 fine (confirmed via the dedicated debug connector; the earlier "2026.04
# won't boot" was a console-routing red herring — see local/rpi-blacksail.inc and
# the memory note project_rpi5_blacksail_uboot_silent).
#
# The repos/${WENDYOS_LAYER_TREE}/ paths resolve to repos/blacksail/* because the
# board's repos.overrides sets WENDYOS_LAYER_TREE="blacksail".

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-raspberrypi \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-rpi-extensions \
    "

# LAYERSERIES_COMPAT safety net for meta-raspberrypi. At the pinned SRCREV_RPI
# (see the board's repos.overrides) meta-raspberrypi declares "wrynose", which
# already intersects oe-core's LAYERSERIES_CORENAMES ("wrynose blacksail") — so
# this is normally redundant. It is kept as a cheap guard in case the pin is ever
# moved back to a commit that declares neither.
#
# If needed, it MUST live in this bblayers include, NOT in local.conf:
# cookerdata.py snapshots each layer's LAYERSERIES_COMPAT and deletes it *during*
# the layer.conf loop, running the compat check there — before local.conf (a
# postfile) is parsed. A bblayers include is parsed while bblayers.conf is read,
# i.e. before the loop, so this :append is registered in time to be captured.
LAYERSERIES_COMPAT_raspberrypi:append = " blacksail"
