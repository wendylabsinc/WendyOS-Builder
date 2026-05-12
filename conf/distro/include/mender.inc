
# Image outputs: disk + OTA artifact
# IMAGE_FSTYPES += "uefiimg mender ext4"

INHERIT += "mender-full"

# Enable automatic data partition growth on first boot
# This allows the data partition to expand to use all available disk space
MENDER_FEATURES_ENABLE:append = " mender-growfs-data"

# Mender artifact naming and daemon polling intervals.
# Reproducible artifact name across rebuilds — DATETIME would force a new
# artifact every build. ${IMAGE_BASENAME} / ${IMAGE_VERSION_SUFFIX} are
# recipe-time variables; BB lazy expansion resolves them when the image
# recipe is parsed.
MENDER_ARTIFACT_NAME = "${IMAGE_BASENAME}-${MACHINE}-${IMAGE_VERSION_SUFFIX}"
# MENDER_ARTIFACT_NAME = "${IMAGE_BASENAME}-${DISTRO_VERSION}-${DATETIME}"

MENDER_UPDATE_POLL_INTERVAL_SECONDS    = "1800"
MENDER_INVENTORY_POLL_INTERVAL_SECONDS = "28800"
MENDER_RETRY_POLL_INTERVAL_SECONDS     = "300"
MENDER_SYSTEMD_AUTO_ENABLE = "1"
MENDER_CONNECT_ENABLE = "1"

# tegra-support-sanity and distro_layer_buildinfo only work as intended
# when inherited in the OE4t setup-env.sh-style environment (they modify
# bblayers.conf and expect host info we don't provide). Removing them is
# a no-op on machines that don't inherit them, so this is safe to apply
# universally. tegra-mender-setup is Tegra-specific and lives in
# conf/distro/include/tegra-image.inc.
INHERIT:remove = "tegra-support-sanity distro_layer_buildinfo"
