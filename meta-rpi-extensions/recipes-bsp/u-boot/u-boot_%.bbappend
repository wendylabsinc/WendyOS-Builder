FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# === RPi5 (BCM2712): U-Boot v2026.07-rc4 fleet-wide + boot-wedge fixes ===
#
# RPi5 U-Boot needs two things missing from oe-core v2026.04:
#   1. the BCM2712 PCIe driver (brcm,bcm2712-pcie + bcm2712_cfg), mainline ~June
#      2026, ships in v2026.07 -- required for NVMe boot;
#   2. our drivers/nvme/nvme.c phys->bus DMA fix (files/0001-nvme-phys-to-bus.patch,
#      not upstream): BCM2712 inbound dma-ranges maps PCIe bus 0x10_00000000 ->
#      CPU 0x0, and stock nvme.c programs raw CPU phys, so nvme_init times out
#      (-110). The patch translates every controller DMA address + recovers the
#      DMA constraints. VALIDATED on hardware (SD-less NVMe boot + A/B OTA).
#
# rc4 applies to the WHOLE rpi5 family (SD + NVMe), not just NVMe. PR #154
# briefly scoped it to :raspberrypi5-nvme and returned the SD machine to stock
# 2026.04, but 2026.04 never booted a Pi 5 SD in this repo (the original
# blacksail bring-up could not boot until the rc4 bump, and the field report
# after #154 merged was another dead board), so the scoping was reverted. rc4
# is the only version bench-validated on Pi 5 here; its two known BOOT WEDGES
# are fixed by config fragments instead of a downgrade:
#   - sd-boot.cfg (SD machine only): compile out CONFIG_USE_PREBOOT. rc4's new
#     BCM2712 PCIe driver made the stock preboot "pci enum; usb start;" live,
#     and it hangs some boards (CanaKit Pi 5, fresh flash) before boot.scr.
#     NVMe keeps its own required PREBOOT from nvme-boot.cfg.
#   - rpi5-bootdelay.cfg (both machines, from #154): CONFIG_BOOTDELAY=-2. The
#     autoboot countdown's stdin poll is a known Pi 5 wedge across U-Boot
#     versions; Mender-based 0.16.x shipped -2 (verified in the 0.16.0 binary)
#     and never hit it, nightlies shipped the default 2 and did.
# See docs/docs-ext/rpi5-nvme.md.
#
# No gating needed beyond the machine overrides:
#   - rpi3 / rpi4 are raspberrypi3 / raspberrypi4 machines (U-Boot 2025.04 via
#     meta-lts-mixins), so the :raspberrypi5* overrides are inert on them, and
#     the wildcard filename matches their recipe (NO dangling append -- a
#     version-pinned u-boot_2026.04.bbappend would dangle on those builds).
#
# CAVEAT (restored with the fleet-wide rc4): a raspberrypi5 machine on a
# U-Boot != 2026.04 recipe (the deletable rpi5-*-scarthgap fallback boards,
# U-Boot 2025.04) would get rc4 forced onto the wrong source. Those boards are
# NOT in the CI matrix; if one ever needs to build, move these overrides into
# a blacksail-only include rather than gating here.
#
# Repin rc4 -> v2026.07 stable when it ships (due ~early July 2026), drop the
# DMA patch once the BCM2712 NVMe fix is upstream, and re-evaluate sd-boot.cfg
# once the PCIe-driver hang is fixed upstream (see that file's removal
# condition). See project_rpi_blacksail_migration_plan.

SRC_URI:raspberrypi5 = "git://source.denx.de/u-boot/u-boot.git;protocol=https;branch=master"
SRCREV:raspberrypi5 = "1296a428c67cf103eca482d4a63349661c1b799f"

# Skip the autoboot countdown on BOTH rpi5 machines (raspberrypi5-nvme carries
# the raspberrypi5 override). The countdown's stdin poll wedges BCM2712 hard at
# the U-Boot logo; the symptom is reported upstream across 2024.04/2025.04/
# master, so it is NOT rc4-specific. 0.16.x Mender images boot because their
# U-Boot integration sets the same -2. See rpi5-bootdelay.cfg for the
# trade-off (autoboot can no longer be interrupted from serial).
SRC_URI:append:raspberrypi5 = " file://rpi5-bootdelay.cfg"

# SD machine only: compile out CONFIG_USE_PREBOOT ("pci enum; usb start;") --
# the second Pi 5 boot wedge; see sd-boot.cfg for the full story + removal
# condition. Scoped to the exact MACHINE, not :raspberrypi5: the NVMe
# machine's MACHINEOVERRIDES include raspberrypi5, and NVMe boot needs its own
# PREBOOT ("pci enum; nvme scan; ..." from nvme-boot.cfg).
SRC_URI:append:raspberrypi5-wendyos = " file://sd-boot.cfg"

SRC_URI:append:raspberrypi5-nvme = " \
    file://nvme-boot.cfg \
    file://0001-nvme-phys-to-bus.patch \
    "
