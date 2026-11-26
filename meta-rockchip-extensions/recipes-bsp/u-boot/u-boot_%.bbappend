FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# oe-core's stock U-Boot v2026.07 with meta-rockchip's TF-A and DDR blobs.
#
# Orange Pi 5 Pro: the board DTS from Linux 7.3 (moved to dts/upstream) and the
# board itself, which upstream U-Boot does not have yet.
SRC_URI:append:orangepi-5-pro-wendyos = " \
    file://0001-arm64-dts-rockchip-rename-PLDO-regulator-labels-to-m.patch \
    file://0002-arm64-dts-rockchip-refactor-items-from-Orange-Pi-5-b.patch \
    file://0003-arm64-dts-rockchip-Add-Orange-Pi-5-Pro-board-support.patch \
    file://0004-arm64-dts-rockchip-Use-GPIO-function-for-PCIe-reset-.patch \
    file://0005-rockchip-rk3588s-Add-support-for-Orange-Pi-5-Pro.patch \
    "

# What the boot script needs, and the boot-device order of the one image.
SRC_URI:append:rockchip-wendyos = " file://wendyos-boot.cfg"
