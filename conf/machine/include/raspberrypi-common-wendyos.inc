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

# --- WendyOS A/B rootfs slot size (wendyos-update stack) ------------------
# Single knob for the RPi A/B rootfs slots (RPi3/4/5). Drives both the wic
# --fixed-size slots in rpi-wendy-ab*.wks AND the rootfs filesystem, so the ext4
# is built to exactly fill the slot (A/B images are never resized at runtime;
# the slot is frozen at flash — an OTA cannot change it).
WENDYOS_ROOTFS_SLOT_SIZE_MB ?= "8192"
# wic only expands wks vars listed in WICVARS — register it so the
# rpi-wendy-ab*.wks `--fixed-size ${WENDYOS_ROOTFS_SLOT_SIZE_MB}M` resolves.
WICVARS:append = " WENDYOS_ROOTFS_SLOT_SIZE_MB"
# ext4 payload = IMAGE_ROOTFS_SIZE + IMAGE_ROOTFS_EXTRA_SPACE; wendyos-image.bb
# adds +4096 KiB (systemd), so subtract it to land the image on the slot exactly.
IMAGE_ROOTFS_SIZE ?= "${@int(d.getVar('WENDYOS_ROOTFS_SLOT_SIZE_MB')) * 1024 - 4096}"

# --- WendyOS config partition (placed BEFORE /data) ----------------------
# Small FAT32 "config" partition that `wendy os install` seeds with first-boot
# provisioning (WiFi, device name, pre-enrolled identity). wendy-agent consumes
# and erases the seed files on first boot (configpartition.Apply); the partition
# itself PERSISTS (it is not deleted), so it stays a re-seed/recovery channel.
MENDER_EXTRA_PARTS = "config"
MENDER_EXTRA_PARTS[config] = "--label=config --fstype=vfat"
MENDER_EXTRA_PARTS_SIZES_MB[config] = "128"
MENDER_EXTRA_PARTS_MOUNT_LOCATIONS[config] = "/config"
MENDER_EXTRA_PARTS_FSTAB[config] = "vfat defaults,nofail 0 0"

# mender-config-before-data.bbclass reorders the sdimg so the config extra part
# is emitted BEFORE /data, keeping /data the LAST partition so it can grow to fill
# any card on first boot. Layout: boot p1, rootfsA p2, rootfsB p3, extended p4,
# config p5, data p6 (mirrors Tegra's config-before-data). The class is inherited
# (late, so its mender_part_image override wins) from the wendyos-image bbappend.
#
# /data becomes the last logical (p6); Mender derives p5 (it assumes config is
# after /data), so pin it. The /config fstab line is corrected to config's real
# device (p5) by fix_config_fstab_rpi in that same bbappend.
MENDER_DATA_PART_NUMBER = "6"

# mender-growfs-data cannot resize the MBR extended container that holds the
# logical /data, so keep it disabled (counters mender.inc's explicit enable);
# grow-data-part is the /data grower (offline, first boot, no reboot).
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
