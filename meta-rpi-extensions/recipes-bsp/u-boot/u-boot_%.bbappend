FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# === Bump U-Boot to v2026.07-rc4 for ALL RPi5 machines (SD + NVMe) ===
#
# Stock oe-core U-Boot v2026.04 predates BCM2712 (Pi5) PCIe support. The driver
# landed in mainline early June 2026 (drivers/pci/pcie_brcmstb.c gains
# brcm,bcm2712-pcie + bcm2712_cfg) and ships in v2026.07. We are moving to
# v2026.07 for NVMe anyway, so unify the WHOLE rpi5 fleet on rc4 now and
# re-validate SD on it — that de-risks the v2026.07 migration and avoids a
# per-machine U-Boot split. SD keeps booting from mmc exactly as before; only
# the U-Boot version changes for it.
#
# NVMe status on rc4: PCIe link trains and the drive enumerates on the PCI bus,
# but `nvme scan` times out (err=-110, nvme_init incomplete) — an upstream
# maturity gap, expected to be fixed in the v2026.07 release. See
# docs/docs-ext/rpi5-nvme.md. The nvme-boot.cfg below stays in place for when it
# lands; tryboot is a last resort only if v2026.07 still can't init NVMe.
#
# NOTE (bleeding-edge until v2026.07 ships):
#   - We replace SRC_URI, so the oe-core v2026.04 dtc patch is dropped; rc4
#     should not need it. If do_compile fails on dtc/yaml, revisit.
#   - Re-validate SD end-to-end on rc4 (boot + A/B OTA), since its U-Boot changed.
#   - When v2026.07 is released, repin SRCREV:raspberrypi5 to the stable tag
#     (check-jp7.2-upstream.sh item 10 flags this).

SRC_URI:raspberrypi5 = "git://source.denx.de/u-boot/u-boot.git;protocol=https;branch=master"
SRCREV:raspberrypi5 = "1296a428c67cf103eca482d4a63349661c1b799f"

# NVMe bits — nvme machine ONLY, appended on top of the shared rc4 SRC_URI above.
#  - nvme-boot.cfg: SD machine must NOT get CONFIG_ENV_FAT_INTERFACE="nvme"
#    (its env lives on mmc), so the config is nvme-only.
#  - 0001-nvme-phys-to-bus.patch: rc4's drivers/nvme/nvme.c programs the
#    controller with raw CPU phys addresses, but BCM2712's inbound dma-ranges
#    maps bus 0x10_00000000 -> CPU 0x0, so the controller can't reach its
#    queues -> nvme_init() times out (-110) despite PCIe link-up + enumeration.
#    The patch wraps every controller-visible DMA address in dev_phys_to_bus()
#    (a no-op on identity platforms). Not upstream as of rc4/master; see
#    docs/docs-ext/rpi5-nvme.md. UNTESTED on hardware — verify on the nvme boot.
SRC_URI:append:raspberrypi5-nvme = " \
    file://nvme-boot.cfg \
    file://0001-nvme-phys-to-bus.patch \
    "
