
# Flash Image Size Configurations for WendyOS
#
# This file defines custom partition sizes for Tegra flash images.
# Device size is set by TEGRA_EXTERNAL_DEVICE_SECTORS; the A/B rootfs (APP)
# slot size is set by MENDER_STORAGE_TOTAL_SIZE_MB (see below — NOT
# ROOTFSPART_SIZE_DEFAULT, which Mender's tegra-mender-setup overrides).
#
# Usage: Set WENDYOS_FLASH_IMAGE_SIZE in local.conf or distro config
#        Values: "4GB", "8GB", "16GB", "32GB", "64GB" (default: "8GB")

WENDYOS_FLASH_IMAGE_SIZE ??= "8GB"

# Total sectors for different image sizes (sector size = 512 bytes)
# Formula: (SIZE_IN_GB * 1000 * 1000 * 1000) / 512
TEGRA_EXTERNAL_DEVICE_SECTORS:4GB = "7812500"
TEGRA_EXTERNAL_DEVICE_SECTORS:8GB = "15625000"
TEGRA_EXTERNAL_DEVICE_SECTORS:16GB = "31250000"
TEGRA_EXTERNAL_DEVICE_SECTORS:32GB = "62500000"
TEGRA_EXTERNAL_DEVICE_SECTORS:64GB = "125000000"

# Override based on WENDYOS_FLASH_IMAGE_SIZE
TEGRA_EXTERNAL_DEVICE_SECTORS = "${TEGRA_EXTERNAL_DEVICE_SECTORS:${WENDYOS_FLASH_IMAGE_SIZE}}"

# Storage budget (in MiB — Mender multiplies by 1048576) that the A/B rootfs
# slots are carved from. Mender sizes EACH slot as
#   (MENDER_STORAGE_TOTAL_SIZE_MB - MENDER_DATA_PART_SIZE_MB[512]) / 2,
# so THIS value — not the device size (TEGRA_EXTERNAL_DEVICE_SECTORS above) —
# sets the per-slot rootfs size; leftover device space flows to the
# auto-growing /data. The rootfs partition size is frozen at flash and CANNOT
# be changed by an OTA, so it must be right here.
#
#   per-slot MiB = (value - 512) / 2
#   64GB -> 25088 => 12288 MiB = 12.0 GiB/slot   (Jetson target)
#           alt 33280 => 16.0 GiB/slot; old 51000 => 24.65 GiB/slot (oversized)
#   4/8/16/32GB buckets keep their historical fill-the-device values.
MENDER_STORAGE_TOTAL_SIZE_MB = "${@{'4GB': '3200', '8GB': '6400', '16GB': '12800', '32GB': '25700', '64GB': '25088'}.get(d.getVar('WENDYOS_FLASH_IMAGE_SIZE'), '6400')}"
