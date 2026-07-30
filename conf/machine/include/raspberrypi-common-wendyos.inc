# Common WendyOS settings for all 64-bit RPi machines (RPi3/4/5).
# Required after the upstream raspberrypiN-64.conf include in each
# machine conf so machine-specific overrides come last where needed.

# The wendy A/B wks layouts handle the disk image; rpi-sdimg from
# meta-raspberrypi would compete. Tegra/UEFI types don't apply.
IMAGE_FSTYPES:remove = "tegraflash dataimg uefiimg uefiimg.bmap uefiimg.bz2 rpi-sdimg"

LICENSE_FLAGS_ACCEPTED += "synaptics-killswitch"

# All RPi machines run the wendyos-update OTA stack (the wendyos.conf
# default); the A/B disk layout comes from the per-machine rpi-wendy-ab*.wks
# (config partition before /data, /data last so it can grow to fill the
# medium on first boot via grow-data-part). The FAT32 "config" partition is
# seeded by `wendy os install` with first-boot provisioning; wendy-agent
# consumes and erases the seed files (configpartition.Apply) but the
# partition itself persists as a re-seed/recovery channel.

# U-Boot provides the A/B slot selection (boot-ab.cmd boot script).
WENDYOS_RPI_UBOOT ?= "1"
RPI_USE_U_BOOT = "${@'1' if d.getVar('WENDYOS_RPI_UBOOT') == '1' else '0'}"

# No UEFI capsule on RPi (the A/B swap covers the rootfs; RPi firmware blobs
# ride in the boot FAT).
WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_EFI_DEBUG ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
# Persistent journal can be turned on once /data is verified to be mounted
# correctly; default off for now to preserve existing behavior.
WENDYOS_PERSIST_JOURNAL_LOGS ?= "0"
WENDYOS_MDNS_INTERFACES ?= ""
WENDYOS_DEBUG ?= "0"

# Driver add-ons (systemd-sysext) are an RPi feature for now; enable here so the
# distro-wide default stays "0" and Jetson/QEMU images are untouched.
WENDYOS_DRIVER_EXTENSIONS ?= "1"

# RPi boot config (consumed by rpi-config_%.bbappend)
ENABLE_UART = "1"
ENABLE_DWC2_PERIPHERAL = "${@oe.utils.ifelse(d.getVar('WENDYOS_USB_GADGET') == '1', '1', '0')}"
DISABLE_RPI_BOOT_LOGO = "1"
DISABLE_SPLASH = "1"
DISABLE_OVERSCAN = "1"

SERIAL_CONSOLES_CHECK = ""
EXTRADEPS = ""
