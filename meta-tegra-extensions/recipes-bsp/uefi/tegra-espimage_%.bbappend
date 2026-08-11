# Size the EFI system partition image to its actual on-disk partition.
#
# Upstream tegra-espimage.bb pins the FAT32 image to 64 MiB
# (IMAGE_ROOTFS_SIZE / IMAGE_ROOTFS_MAXSIZE = 65536 KiB), and
# image_types_tegra_esp.bbclass:oe_mkespfs allocates exactly that many KiB
# (`dd ... seek=${IMAGE_ROOTFS_SIZE} bs=1024`) before running mkfs.vfat over it.
# tegraflash then writes that fixed-size image into whatever the BSP's flash
# layout declares for the `esp` partition, and nothing ever grows the
# filesystem afterwards (unlike /data, which wendyos-data-setup formats and
# grows on first boot).
#
# On t234 the partition is 67108864 B == 64 MiB, so upstream is an exact fit.
# On t264 (Thor) NVIDIA's layout allocates 512 MiB and the image did not follow,
# leaving a 63 MiB filesystem inside a 512 MiB partition — 87% of the partition
# unreachable. That matters because Thor is the only SOC that stages UEFI
# capsules (wendyos-update gates capsule staging on tegra264): tegra-bl.cap is
# ~20.3 MiB, so a third of the usable ESP has to be free for every bootloader
# OTA, and any leaked space is unrecoverable in the field without a reflash.
#
# WENDYOS_ESP_SIZE is in KiB and defaults to upstream's value, so this appends
# nothing unless a machine opts in (see conf/template/include/local/tegra-*.inc).
# It must not exceed the `esp` partition size in that machine's flash layout —
# tegraflash rejects an image larger than its partition.
WENDYOS_ESP_SIZE ?= "65536"

IMAGE_ROOTFS_SIZE = "${WENDYOS_ESP_SIZE}"
IMAGE_ROOTFS_MAXSIZE = "${WENDYOS_ESP_SIZE}"
