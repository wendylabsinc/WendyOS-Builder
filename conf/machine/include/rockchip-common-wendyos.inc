# Common WendyOS settings for Rockchip machines. Required after meta-rockchip's
# SoC include (rk3588s.inc, rk3588.inc, ...) in each machine conf.

# linux-yocto 7.2: Ethernet on the Orange Pi 5 Pro (Motorcomm YT6801,
# CONFIG_DWMAC_MOTORCOMM) first shipped in Linux 7.0.
PREFERRED_VERSION_linux-yocto = "7.2%"

# The boot script loads /boot/Image and /boot/<dtb basename> from the booted
# slot. OTA never rewrites the script, so both paths are a permanent contract.
KERNEL_IMAGETYPE = "Image"
KERNEL_DTBVENDORED = "0"
WENDYOS_ROCKCHIP_DTB = "${@os.path.basename(d.getVar('KERNEL_DEVICETREE').split()[0])}"

# The defconfig builds Ethernet, Wi-Fi, GPU and the USB PHYs as modules.
MACHINE_EXTRA_RRECOMMENDS += "kernel-modules"

# The wendy A/B layout replaces meta-rockchip's extlinux boot and rockchip.wks:
# an extlinux.conf in each slot would be a second boot path that ignores the
# selected slot.
UBOOT_EXTLINUX = "0"
MACHINE_ESSENTIAL_EXTRA_RDEPENDS:remove = "u-boot-extlinux"
WKS_FILE = "rockchip-wendy-ab.wks"
# A family-specific name, so U-Boot never sources a Pi card's boot.scr. Also
# spelled out in wendyos-boot.cfg.
WENDYOS_ROCKCHIP_BOOT_SCRIPT = "wendyos-rockchip.scr"
IMAGE_BOOT_FILES = "${WENDYOS_ROCKCHIP_BOOT_SCRIPT}"

# Size of uboot.env, a permanent contract: the flashed boot script fixes it.
# Must equal U-Boot's CONFIG_ENV_SIZE (wendyos-boot.cfg).
WENDYOS_UBOOT_ENV_SIZE = "0x8000"

# No UEFI capsule: the A/B swap covers the rootfs, and OTA never touches the
# bootloader in the raw area before p1.
WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_EFI_DEBUG ?= "0"

# SD-card boards: keep the journal off the card, as on the Pi.
WENDYOS_PERSIST_JOURNAL_LOGS ?= "0"

# AP6256 Wi-Fi firmware comes from Raspberry Pi under the Synaptics licence.
LICENSE_FLAGS_ACCEPTED += "synaptics-killswitch"

# The board conf names its hardware packagegroup.
WENDYOS_ROCKCHIP_BOARD_PACKAGEGROUP ?= ""

MACHINE_FEATURES:append = " usbhost vfat ext2 alsa rtc pci"
