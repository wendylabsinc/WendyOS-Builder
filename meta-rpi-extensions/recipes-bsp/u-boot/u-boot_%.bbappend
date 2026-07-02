FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# === RPi5 (BCM2712) NVMe-over-U-Boot: bump to v2026.07-rc4 + DMA patch ===
#
# RPi5 NVMe boot via U-Boot needs two things missing from oe-core v2026.04:
#   1. the BCM2712 PCIe driver (brcm,bcm2712-pcie + bcm2712_cfg), mainline ~June
#      2026, ships in v2026.07;
#   2. our drivers/nvme/nvme.c phys->bus DMA fix (files/0001-nvme-phys-to-bus.patch,
#      not upstream): BCM2712 inbound dma-ranges maps PCIe bus 0x10_00000000 ->
#      CPU 0x0, and stock nvme.c programs raw CPU phys, so nvme_init times out
#      (-110). The patch translates every controller DMA address + recovers the
#      DMA constraints. VALIDATED on hardware (SD-less NVMe boot + A/B OTA).
# So override U-Boot to the rc4 SRCREV and, on the nvme machine, add the patch +
# nvme-boot.cfg (env-on-nvme, CONFIG_NVME, nvme-scan PREBOOT, bootcmd). See
# docs/docs-ext/rpi5-nvme.md.
#
# No gating needed beyond the machine overrides:
#   - rpi3 / rpi4 are raspberrypi3 / raspberrypi4 machines (U-Boot 2025.04 via
#     meta-lts-mixins), so SRC_URI:raspberrypi5 / :raspberrypi5-nvme are inert on
#     them, and the wildcard filename matches their recipe (NO dangling append --
#     a version-pinned u-boot_2026.04.bbappend would dangle on those builds).
#   - Only the blacksail rpi5 boards (U-Boot 2026.04) get the rc4 bump + patch.
#
# CAVEAT: a raspberrypi5 machine on a U-Boot != 2026.04 (the temporary
# rpi5-*-scarthgap fallback boards, U-Boot 2025.04) would get rc4 forced onto the
# wrong source. Those boards are NOT in the CI matrix and are deletable migration
# fallbacks. If one ever needs to build, move these overrides into a blacksail-only
# layer/include rather than gating here. Repin rc4 -> v2026.07 stable when it ships
# (or drop the patch once the BCM2712 NVMe DMA fix is upstream). See
# project_rpi_blacksail_migration_plan.

SRC_URI:raspberrypi5 = "git://source.denx.de/u-boot/u-boot.git;protocol=https;branch=master"
SRCREV:raspberrypi5 = "1296a428c67cf103eca482d4a63349661c1b799f"

# All rpi5 boards (SD + NVMe): require a stop-string to abort autoboot so a
# floating debug-UART RX (RP1 PL011 on GPIO14/15, dtoverlay=uart0) cannot drop a
# probe-less board to the U-Boot prompt. See files/autoboot-keyed.cfg. Scoped to
# :raspberrypi5 -- rpi3/4 use the biased mini-UART and are unaffected.
SRC_URI:append:raspberrypi5 = " file://autoboot-keyed.cfg"

SRC_URI:append:raspberrypi5-nvme = " \
    file://nvme-boot.cfg \
    file://0001-nvme-phys-to-bus.patch \
    "

