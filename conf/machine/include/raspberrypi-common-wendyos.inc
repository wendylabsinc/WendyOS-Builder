# Common WendyOS settings for all 64-bit RPi machines (RPi3/4/5).
# Required after the upstream raspberrypiN-64.conf include in each
# machine conf so machine-specific overrides come last where needed.

# Mender's mender-image-sd handles the sdimg layout; rpi-sdimg from
# meta-raspberrypi would compete with it. Tegra/UEFI types don't apply.
IMAGE_FSTYPES:remove = "tegraflash dataimg uefiimg uefiimg.bmap uefiimg.bz2 rpi-sdimg"

LICENSE_FLAGS_ACCEPTED += "synaptics-killswitch"

# Mender opt-in (wendyos.conf default is "none" for RPi).
WENDYOS_OTA = "mender"

# U-Boot is on by default (Mender's upstream-supported path).
WENDYOS_RPI_UBOOT ?= "1"
RPI_USE_U_BOOT = "${@'1' if d.getVar('WENDYOS_RPI_UBOOT') == '1' else '0'}"

# Mender storage geometry. SD card on /dev/mmcblk0 with partition suffix
# 'p' (e.g. /dev/mmcblk0p2). 7528 MiB (7400 + the 128 MiB config part below)
# fits a nominal 8 GB SD card. raspberrypi5-nvme-wendyos.conf overrides
# MENDER_STORAGE_DEVICE and MENDER_STORAGE_TOTAL_SIZE_MB for NVMe.
# MENDER_STORAGE_DEVICE_BASE uses lazy expansion so the NVMe override of
# MENDER_STORAGE_DEVICE alone is enough to derive /dev/nvme0n1p* names.
MENDER_STORAGE_DEVICE        = "/dev/mmcblk0"
MENDER_STORAGE_DEVICE_BASE   = "${MENDER_STORAGE_DEVICE}p"
MENDER_BOOT_PART_SIZE_MB     = "100"
MENDER_DATA_PART_SIZE_MB     = "256"
MENDER_STORAGE_TOTAL_SIZE_MB = "7528"

# --- WendyOS config partition --------------------------------------------
# Small FAT32 "config" partition that `wendy os install` seeds with first-boot
# provisioning (WiFi, device name, pre-enrolled identity, agent binary).
# wendy-agent consumes and erases it on first boot (configpartition.Apply);
# reclaim-config-part then deletes it and grows /data over the freed space.
# Injected as a Mender extra part (mender-image-sd owns the sdimg layout);
# Mender writes the /config fstab line. nofail: the partition is gone after
# first boot, so the mount must not block later boots.
MENDER_EXTRA_PARTS = "config"
MENDER_EXTRA_PARTS[config] = "--label=config --fstype=vfat"
MENDER_EXTRA_PARTS_SIZES_MB[config] = "128"
MENDER_EXTRA_PARTS_MOUNT_LOCATIONS[config] = "/config"
MENDER_EXTRA_PARTS_FSTAB[config] = "vfat defaults,nofail 0 0"

# Extra parts land after /data, so mender-growfs-data would try to grow /data
# over /config. Disable it (counters mender.inc's explicit enable);
# reclaim-config-part is the sole /data grower.
MENDER_FEATURES_DISABLE:append = " mender-growfs-data"

# No UEFI capsule on RPi (Mender handles rootfs A/B; firmware blobs are
# staged best-effort by meta-mender-raspberrypi's
# update-firmware-state-script).
WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_EFI_DEBUG ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
# Persistent journal can be turned on once /data is verified to be mounted
# correctly post-Mender; default off for now to preserve existing behavior.
WENDYOS_PERSIST_JOURNAL_LOGS ?= "0"
WENDYOS_MDNS_INTERFACES ?= ""
WENDYOS_DEBUG ?= "0"

# RPi boot config (consumed by rpi-config_%.bbappend)
ENABLE_UART = "1"
ENABLE_DWC2_PERIPHERAL = "${@oe.utils.ifelse(d.getVar('WENDYOS_USB_GADGET') == '1', '1', '0')}"
DISABLE_RPI_BOOT_LOGO = "1"
DISABLE_SPLASH = "1"
DISABLE_OVERSCAN = "1"

SERIAL_CONSOLES_CHECK = ""
EXTRADEPS = ""
