# RPi layers for the blacksail tree (WENDYOS_LAYER_TREE = "blacksail"), used by
# the rpi3-sd / rpi4-sd / rpi5-sd / rpi5-nvme board templates. Uses the wendy OTA
# stack: meta-rpi-extensions supplies the A/B boot.cmd via its
# rpi-u-boot-scr.bbappend.
#
# Nothing is layered beyond meta-raspberrypi and meta-rpi-extensions. Go and
# U-Boot both come from blacksail oe-core, so no backport layer is cloned or
# layered. The Pi 5 uses oe-core's stock U-Boot v2026.07, with the boot fixes in
# meta-rpi-extensions' u-boot bbappend.
#
# The repos/${WENDYOS_LAYER_TREE}/ paths resolve to repos/blacksail/* because the
# board's repos.overrides sets WENDYOS_LAYER_TREE="blacksail".

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-raspberrypi \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-rpi-extensions \
    "
