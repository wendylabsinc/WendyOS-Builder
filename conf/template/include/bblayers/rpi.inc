# RPi-exclusive layers: meta-raspberrypi base, our extensions, the
# upstream Mender layers, and meta-lts-mixins for a backported U-Boot.
#
# meta-lts-mixins ships u-boot_2025.04.bb which wins over
# poky-scarthgap's u-boot_2024.01.bb by version selection. We need 2025.04
# for two reasons:
#   - RPi5 (BCM2712) is unsupported in poky's u-boot_2024.01.bb.
#   - meta-mender-raspberrypi's U-Boot patches are authored against
#     2025.04 defconfigs and fail to apply on 2024.01.
# This mirrors upstream meta-mender-community/kas/include/raspberrypi.yml
# which pulls meta-lts-mixins for every RPi target (rpi0..rpi5).
#
# All 64-bit RPi machines (RPi3/4/5) share UBOOT_MACHINE = "rpi_arm64_config"
# upstream, so meta-mender-raspberrypi's U-Boot patches apply identically
# to each. Per-machine Mender storage geometry lives in the machine confs
# (RPi3/4 and RPi5-SD use 7400 MiB total; RPi5-NVMe overrides to 32 GiB).
# All three default WENDYOS_RPI_UBOOT="1".

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-raspberrypi \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-rpi-extensions \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-mender/meta-mender-core \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-mender-community/meta-mender-raspberrypi \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-lts-mixins \
    "
