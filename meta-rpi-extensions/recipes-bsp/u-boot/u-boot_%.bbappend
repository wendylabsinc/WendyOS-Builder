FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# === NVMe boot for the Raspberry Pi 5 (raspberrypi5-nvme machine ONLY) ===
#
# The SD machine stays on stock oe-core U-Boot v2026.04. That version predates
# BCM2712 (Pi5) PCIe support, so U-Boot on it cannot see the NVMe at all
# (`nvme scan` -> "Unknown command", boot_targets=mmc usb pxe dhcp). See
# docs/docs-ext/rpi5-nvme.md.
#
# The BCM2712 PCIe driver landed in mainline U-Boot in early June 2026
# (drivers/pci/pcie_brcmstb.c gains brcm,bcm2712-pcie + bcm2712_cfg) and ships in
# v2026.07. So for the NVMe machine we bump U-Boot to v2026.07-rc4 (the latest
# tagged RC at 2026-06-22 that contains the driver) and add the nvme-boot.cfg
# fragment. This keeps the existing ubootenv connector + boot-ab.cmd.in A/B
# mechanism (its nvme overrides -- `nvme scan` precmd, WENDYOS_UBOOT_DEV=nvme --
# are already wired; they just needed a U-Boot that has the nvme command).
#
# Scoped to :raspberrypi5-nvme so the validated SD build is untouched.
#
# NOTE: this is bleeding-edge U-Boot (driver merged weeks ago, still churning,
# not in a stable release until ~v2026.07). Things to verify/iterate on at build
# and boot time:
#   - the oe-core v2026.04 dtc patch is dropped here (we replace SRC_URI); rc4
#     should not need it. If do_compile fails on dtc/yaml, revisit.
#   - u-boot.bin size: adding NVMe+PCIe grows the binary; if the RPi firmware
#     rejects it, a size/feature trim may be needed.
#   - boot target: with CONFIG_BOOTSTD_DEFAULTS, enabling NVMe should get the
#     drive scanned for boot.scr; the PREBOOT `nvme scan` is the belt-and-braces.
#     Confirm on-device with `nvme scan` + that boot.scr loads from nvme.
#   - env-on-nvme: CONFIG_ENV_FAT_INTERFACE="nvme" (in nvme-boot.cfg). Confirm
#     U-Boot reads/writes uboot.env on the NVMe and the A/B slot flip persists.
#
# When v2026.07 is released, repin SRCREV to the stable tag.

SRC_URI:raspberrypi5-nvme = "git://source.denx.de/u-boot/u-boot.git;protocol=https;branch=master \
                             file://nvme-boot.cfg"
SRCREV:raspberrypi5-nvme = "1296a428c67cf103eca482d4a63349661c1b799f"

