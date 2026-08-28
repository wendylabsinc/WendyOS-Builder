# Size the EFI system partition image to the machine's real `esp` partition.
#
# Upstream tegra-espimage.bb pins the FAT32 image to 64 MiB (IMAGE_ROOTFS_SIZE
# and IMAGE_ROOTFS_MAXSIZE both 65536 KiB), and
# image_types_tegra_esp.bbclass:oe_mkespfs allocates exactly that many KiB
# (`dd ... seek=${IMAGE_ROOTFS_SIZE} bs=1024`) before running mkfs.vfat over it.
# The filesystem size is therefore fixed at build time. tegraflash writes that
# image into whatever the BSP flash layout declares for `esp`, and nothing ever
# grows an ESP afterwards -- unlike /data, which wendyos-data-setup formats and
# grows on first boot.
#
# Where the partition is larger than the image, the difference is unreachable,
# not merely unused. On t234 the partition is 67108864 B, so upstream is an exact
# fit. NVIDIA's t264 layout allocates 536870912 B, so a flashed Thor ran a
# 66059264 B filesystem inside a 512 MiB partition, with 87.7% of the partition
# out of reach. Measured on device: `df -B1 /boot/efi` reports 66059264 total.
#
# The consumer of that space is UEFI capsule staging. wendyos-update copies
# tegra-bl.cap to EFI/UpdateCapsule/TEGRA_BL.Cap before a bootloader update,
# 21276567 B on r39.2 t264. This is headroom, not a leak fix: a full staging and
# apply cycle returns the filesystem to its baseline, measured on Thor with `df`
# used going 112128 -> 21389312 -> 112640 bytes. t234 stages capsules too, but
# its partition really is 64 MiB, so it has nothing to reclaim and has to stay at
# the upstream value.
#
# WENDYOS_ESP_SIZE is in KiB and defaults to upstream's value, so this appends
# nothing unless a machine opts in. Set it in the machine conf, next to the other
# values tied to that machine's flash layout. It must not exceed that machine's
# `esp` size: l4t_create_images_for_kernel_flash.sh refuses an image larger than
# its partition, and so does the device-side writer (bootburn_t264_py's
# bootburn_adb.py, `FileSize > partitionInfo.Size`). Both compare strictly, so an
# exactly-partition-sized image is accepted.
WENDYOS_ESP_SIZE ?= "65536"

IMAGE_ROOTFS_SIZE = "${WENDYOS_ESP_SIZE}"
IMAGE_ROOTFS_MAXSIZE = "${WENDYOS_ESP_SIZE}"
