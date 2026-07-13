# RPi layers for the blacksail-tree experiment (WENDYOS_LAYER_TREE = "blacksail").
# Like bblayers/rpi-wendy.inc (the scarthgap wendy stack) but without the Go
# mixin: blacksail oe-core ships Go 1.26 natively, so the meta-lts-mixins-go
# backport is neither cloned (the board's repos.overrides omits its REPOS_EXTRA)
# nor layered.
#
# No meta-lts-mixins: blacksail oe-core's NATIVE U-Boot 2026.04 boots the Pi 5
# fine (confirmed via the dedicated debug connector; the earlier "2026.04 won't
# boot" was a console-routing red herring — see local/rpi-blacksail.inc and the
# memory note project_rpi5_blacksail_uboot_silent), so the 2025.04 backport is
# not needed.
#
# The repos/${WENDYOS_LAYER_TREE}/ paths resolve to repos/blacksail/* because the
# board's repos.overrides sets WENDYOS_LAYER_TREE="blacksail". meta-raspberrypi
# is pinned to the same SRCREV_RPI as scarthgap (kernel 6.6 + BCM2712 support);
# its layer.conf only declares scarthgap, so it is bridged for blacksail below.
#
# Uses the wendy OTA stack.

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-raspberrypi \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-rpi-extensions \
    "

# LAYERSERIES_COMPAT safety net for meta-raspberrypi. With SRCREV_RPI bumped to
# upstream master (see the board's repos.overrides), meta-raspberrypi declares
# "wrynose", which already intersects oe-core's LAYERSERIES_CORENAMES
# ("wrynose blacksail") — so this is normally redundant. It's kept as a cheap
# guard in case the pin is ever moved back to an older (scarthgap-only) commit.
#
# If needed, it MUST live in this bblayers include, NOT in local.conf:
# cookerdata.py snapshots each layer's LAYERSERIES_COMPAT and deletes it *during*
# the layer.conf loop, running the compat check there — before local.conf (a
# postfile) is parsed. A bblayers include is parsed while bblayers.conf is read,
# i.e. before the loop, so this :append is registered in time to be captured.
LAYERSERIES_COMPAT_raspberrypi:append = " blacksail"
