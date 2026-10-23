FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# === RPi5 (BCM2712): boot fixes on top of oe-core's stock U-Boot ===
#
# Both Pi 5 machines (SD and NVMe) build oe-core's U-Boot v2026.07, which has
# the BCM2712 PCIe driver NVMe boot needs. We add three things:
#   - files/0001-nvme-phys-to-bus.patch (NVMe machine only, not upstream):
#     BCM2712 inbound dma-ranges maps PCIe bus 0x10_00000000 -> CPU 0x0, and
#     stock nvme.c programs raw CPU addresses, so nvme_init times out (-110).
#     The patch translates every controller DMA address and recovers the DMA
#     constraints. Validated on hardware (SD-less NVMe boot + A/B OTA).
#   - sd-boot.cfg (SD machine only): compiles out CONFIG_USE_PREBOOT. The
#     stock preboot "pci enum; usb start;" hangs some boards before boot.scr.
#     The NVMe machine keeps its own PREBOOT from nvme-boot.cfg.
#   - rpi5-bootdelay.cfg (both machines): CONFIG_BOOTDELAY=-2. The autoboot
#     countdown's stdin poll is a known Pi 5 wedge across U-Boot versions.
#
# These were validated on 2026.07-rc4, which is an ancestor of v2026.07. The
# commits between them do not touch drivers/nvme or drivers/pci.
#
# rpi3 / rpi4 are raspberrypi3 / raspberrypi4 machines, so the :raspberrypi5*
# overrides are inert on them. The wildcard filename matches their recipe too,
# so this append never dangles.
#
# Drop the DMA patch once the BCM2712 NVMe fix is upstream, and re-evaluate
# sd-boot.cfg once the PCIe-driver hang is fixed upstream (see that file's
# removal condition).

# Skip the autoboot countdown on BOTH rpi5 machines (raspberrypi5-nvme carries
# the raspberrypi5 override). The countdown's stdin poll wedges BCM2712 hard at
# the U-Boot logo; the symptom is reported upstream across 2024.04/2025.04/
# master, so it is NOT rc4-specific. The 0.16.x images boot because their
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
