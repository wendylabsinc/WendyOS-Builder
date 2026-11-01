# One Orin image for the SD, eMMC and NVMe disks of its board. Required after the upstream machine
# conf, whose storage defaults these replace.

# nvme0n1p1 makes the bundle carry the external layout every install target is made from;
# it also aims the bundle's own initrd-flash at the NVMe, with erase-mmc on mmcblk0.
TNSPEC_BOOTDEV = "nvme0n1p1"
# The initramfs takes the root from the disk UEFI booted, so it gets no build-time disk.
TEGRA_MINIMAL_INIT_BOOTDRIVE = ""

# QSPI boot chain, plus one A/B disk layout for SD, eMMC and NVMe
PARTITION_LAYOUT_TEMPLATE_DEFAULT = "flash_t234_qspi.xml"
PARTITION_LAYOUT_TEMPLATE_DEFAULT_SUPPORTS_REDUNDANT = "1"
PARTITION_LAYOUT_EXTERNAL_DEFAULT = "flash_l4t_t234_nvme.xml"

# Raw image geometry: fits a 64 GB SD card or disk; first boot moves the backup GPT and grows /data.
TEGRA_EXTERNAL_DEVICE_SECTORS = "119537664"
