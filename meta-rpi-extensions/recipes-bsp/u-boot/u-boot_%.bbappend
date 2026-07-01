FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# === RPi5 (BCM2712) NVMe-over-U-Boot: v2026.07-rc4 + DMA patch, nvme only ===
#
# RPi5 NVMe boot via U-Boot needs two things missing from oe-core v2026.04:
#   1. the BCM2712 PCIe driver (brcm,bcm2712-pcie + bcm2712_cfg), mainline ~June
#      2026, ships in v2026.07;
#   2. our drivers/nvme/nvme.c phys->bus DMA fix (files/0001-nvme-phys-to-bus.patch,
#      not upstream): BCM2712 inbound dma-ranges maps PCIe bus 0x10_00000000 ->
#      CPU 0x0, and stock nvme.c programs raw CPU phys, so nvme_init times out
#      (-110). The patch translates every controller DMA address + recovers the
#      DMA constraints. VALIDATED on hardware (SD-less NVMe boot + A/B OTA).
# The rc4 bump is scoped to :raspberrypi5-nvme -- the ONLY machine that needs
# PCIe in U-Boot. The SD machine boots from mmc and stays on the stock blacksail
# oe-core U-Boot (2026.04): a fleet-wide :raspberrypi5 bump shipped an -rc
# bootloader to boards that gained nothing from it, and forced rc4 onto the
# wrong source for any raspberrypi5 machine on a non-2026.04 recipe (the old
# CAVEAT re rpi5-*-scarthgap fallbacks -- resolved by this scoping).
# See docs/docs-ext/rpi5-nvme.md.
#
# No gating needed beyond the machine overrides:
#   - rpi3 / rpi4 are raspberrypi3 / raspberrypi4 machines (U-Boot 2025.04 via
#     meta-lts-mixins), so the :raspberrypi5* overrides are inert on them, and
#     the wildcard filename matches their recipe (NO dangling append -- a
#     version-pinned u-boot_2026.04.bbappend would dangle on those builds).
#
# Repin rc4 -> v2026.07 stable when it ships (due ~early July 2026), and drop
# the DMA patch once the BCM2712 NVMe fix is upstream. See
# project_rpi_blacksail_migration_plan.

SRC_URI:raspberrypi5-nvme = "git://source.denx.de/u-boot/u-boot.git;protocol=https;branch=master"
SRCREV:raspberrypi5-nvme = "1296a428c67cf103eca482d4a63349661c1b799f"

# Skip the autoboot countdown on BOTH rpi5 machines (raspberrypi5-nvme carries
# the raspberrypi5 override). The countdown's stdin poll wedges BCM2712 hard at
# the U-Boot logo before the banner prints; the symptom is reported upstream
# across 2024.04/2025.04/master, so it is NOT rc4-specific -- the stock 2026.04
# the SD machine now runs needs this as much as rc4 does. 0.16.x Mender images
# boot because their U-Boot integration sets the same -2. See rpi5-bootdelay.cfg
# for the trade-off (autoboot can no longer be interrupted from serial).
SRC_URI:append:raspberrypi5 = " file://rpi5-bootdelay.cfg"

SRC_URI:append:raspberrypi5-nvme = " \
    file://nvme-boot.cfg \
    file://0001-nvme-phys-to-bus.patch \
    "
