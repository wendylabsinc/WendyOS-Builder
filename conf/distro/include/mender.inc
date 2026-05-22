
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
# universally.
INHERIT:remove = "tegra-support-sanity distro_layer_buildinfo"

# tegra-mender-setup is Tegra-only (l4t-mender override injection,
# tegraflash artifact type, NVIDIA partition table). It must be inherited
# at config-parse time — bitbake reads INHERIT exactly once, at the end
# of global config parsing, before any recipe is read. mender.inc is
# required from wendyos.conf (distro scope) so this line takes effect;
# putting the same line in a recipe-included .inc (e.g. tegra-image.inc
# required from wendyos-image.bb) would be a silent no-op.
# Lazy Python expansion gates the inherit on a Tegra MACHINEOVERRIDE so
# non-Tegra builds don't try to load the class.
INHERIT += "${@'tegra-mender-setup' if 'tegra' in d.getVar('MACHINEOVERRIDES').split(':') else ''}"
