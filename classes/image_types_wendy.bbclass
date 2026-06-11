# image_types_wendy.bbclass
#
# Defines the "wendy" IMAGE_FSTYPE: a .wendy OTA artifact for the
# wendy-update client, produced by running `wendy-update pack` on the
# image's ext4 rootfs. Replaces mender-artifactimg.bbclass for boards
# using the wendy-update OTA stack (WENDYOS_OTA = "wendy").
#
# Enable per build by adding to the image's fstypes + classes (done in
# the OTA wiring, gated on WENDYOS_OTA == "wendy"):
#   IMAGE_CLASSES += "image_types_wendy"
#   IMAGE_FSTYPES += "wendy"
#
# The artifact format and `pack` are documented in the wendy-os-update
# repo (docs/manifest-schema.md, docs/cli-contract.md).

# The artifact payload is the raw rootfs ext4; force it to be built even
# when the machine's IMAGE_FSTYPES only lists tegraflash-tar.
WENDY_ARTIFACTIMG_FSTYPE ?= "ext4"
IMAGE_TYPEDEP:wendy:append = " ${WENDY_ARTIFACTIMG_FSTYPE}"

# `wendy-update pack` runs on the build host (native variant of the
# client recipe — BBCLASSEXTEND = "native").
do_image_wendy[depends] += "wendyos-update-native:do_populate_sysroot"

# Artifact identity. Reproducible across rebuilds — use DISTRO_VERSION,
# NOT IMAGE_VERSION_SUFFIX (oe-core defaults the latter to "-${DATETIME}",
# which would make every rebuild a new artifact with a malformed name).
# --device is the value the device records in /etc/wendyos/device-type
# (BOARD=), which the client matches against the artifact's
# compatible_devices at install time.
WENDY_ARTIFACT_VERSION ?= "${DISTRO_VERSION}"
WENDY_ARTIFACT_NAME ?= "${IMAGE_BASENAME}-${MACHINE}-${WENDY_ARTIFACT_VERSION}"
WENDY_ARTIFACT_COMPRESSION ?= "zstd"

IMAGE_CMD:wendy () {
    if [ -z "${WENDYOS_BOARD_ID}" ]; then
        bbfatal "image_types_wendy: WENDYOS_BOARD_ID is unset; cannot set the artifact's compatible device"
    fi
    wendy-update pack \
        --image ${IMGDEPLOYDIR}/${IMAGE_LINK_NAME}.${WENDY_ARTIFACTIMG_FSTYPE} \
        --name ${WENDY_ARTIFACT_NAME} \
        --version ${WENDY_ARTIFACT_VERSION} \
        --device ${WENDYOS_BOARD_ID} \
        --compression ${WENDY_ARTIFACT_COMPRESSION} \
        -o ${IMGDEPLOYDIR}/${IMAGE_NAME}${IMAGE_NAME_SUFFIX}.wendy
}

# IMAGE_ID embeds a timestamp; excluding it keeps the artifact's signature
# stable across otherwise-identical rebuilds.
IMAGE_CMD:wendy[vardepsexclude] += "IMAGE_ID"
