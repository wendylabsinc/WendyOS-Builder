# WendyOS kernel deltas for the Rockchip boards: linux-yocto 7.2 built from the
# arm64 defconfig (meta-rockchip's KBUILD_DEFCONFIG), plus the fragments below.
FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"

# linux-yocto lists the machines it builds for; meta-rockchip adds only its own.
COMPATIBLE_MACHINE:rockchip-wendyos = "rockchip-wendyos"

require ${@'recipes-kernel/linux/game-controller.inc' if d.getVar('WENDYOS_GAME_CONTROLLER') == '1' else ''}

SRC_URI:append:rockchip-wendyos = " file://rockchip-wendyos.cfg"

# Orange Pi 5 Pro: the board DTS from Linux 7.3, then the onboard microphone.
SRC_URI:append:orangepi-5-pro-wendyos = " \
    file://0001-arm64-dts-rockchip-rename-PLDO-regulator-labels-to-m.patch \
    file://0002-arm64-dts-rockchip-refactor-items-from-Orange-Pi-5-b.patch \
    file://0003-arm64-dts-rockchip-Add-Orange-Pi-5-Pro-board-support.patch \
    file://0004-arm64-dts-rockchip-Use-GPIO-function-for-PCIe-reset-.patch \
    file://0005-ASoC-dt-bindings-everest-es8328-Add-everest-shared-l.patch \
    file://0006-ASoC-es8328-Support-a-shared-LRCK-on-the-ES8388.patch \
    file://0007-arm64-dts-rockchip-Enable-the-onboard-microphone-on-.patch \
    "

require recipes-kernel/linux/mesh-local.inc
require recipes-kernel/linux/mesh-internet.inc
require recipes-kernel/linux/cve-2026-98432.inc

# Remote SensorLink camera and microphone endpoints need local loopback drivers.
require recipes-kernel/linux/virtual-loopback.inc

# Each of these fails only on a booted board, so check the resolved config here:
# with no initramfs, a modular root-path driver (the SD card's supply comes from
# the RK806 over SPI) hangs at rootwait.
do_configure[postfuncs] += "wendyos_check_rockchip_kernel"
wendyos_check_rockchip_kernel() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "Rockchip kernel: no resolved kernel config at $config"
    for symbol in CONFIG_MMC_DW_ROCKCHIP CONFIG_MMC_SDHCI_OF_DWCMSHC CONFIG_PCIE_ROCKCHIP_DW_HOST \
                  CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY CONFIG_BLK_DEV_NVME CONFIG_EXT4_FS \
                  CONFIG_MFD_RK8XX_SPI CONFIG_REGULATOR_RK808 CONFIG_SPI_ROCKCHIP \
                  CONFIG_PINCTRL_ROCKCHIP CONFIG_GPIO_ROCKCHIP \
                  CONFIG_RTC_DRV_HYM8563 CONFIG_NAMESPACES CONFIG_NET_NS CONFIG_USER_NS \
                  CONFIG_CGROUPS CONFIG_MEMCG CONFIG_SECCOMP_FILTER; do
        grep -q "^$symbol=y$" "$config" || bbfatal "Rockchip kernel: $symbol must be built in for ${MACHINE}"
    done
    for symbol in CONFIG_DWMAC_MOTORCOMM CONFIG_BRCMFMAC CONFIG_DRM_PANTHOR CONFIG_OVERLAY_FS \
                  CONFIG_BRIDGE CONFIG_VETH CONFIG_IP_NF_NAT CONFIG_NETFILTER_XT_TARGET_MASQUERADE; do
        grep -Eq "^$symbol=(y|m)$" "$config" || bbfatal "Rockchip kernel: $symbol is disabled for ${MACHINE}"
    done
}
