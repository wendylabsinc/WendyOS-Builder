# RPi layers for the wendyos-update OTA stack (WENDYOS_OTA = "wendy").
# Identical to bblayers/rpi.inc but WITHOUT the Mender layers: the wendy stack
# replaces Mender entirely, and leaving meta-mender-raspberrypi in BBLAYERS
# would apply its rpi-u-boot-scr.bbappend (Mender's A/B boot.cmd), colliding
# with meta-rpi-extensions' wendy boot.cmd. Used by the rpi5-sd / rpi5-nvme
# board templates; RPi3/4 stay on bblayers/rpi.inc + Mender.
#
# Two meta-lts-mixins checkouts, each a different mixin branch (each mixin lives
# on its own branch, so they can't share a checkout):
#   - meta-lts-mixins     (scarthgap/u-boot): u-boot_2025.04 — RPi5 BCM2712 is
#                         unsupported in poky-scarthgap's u-boot_2024.01.
#   - meta-lts-mixins-go  (scarthgap/go):     Go 1.26.4 — wendyos-update's go.mod
#                         requires go >= 1.26, but scarthgap oe-core ships 1.22.
# The -go checkout is cloned via REPOS_EXTRA in the rpi5-sd / rpi5-nvme
# repos.overrides (pin SRCREV_LTS_MIXINS_GO).

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-raspberrypi \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-rpi-extensions \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-lts-mixins \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-lts-mixins-go \
    "
