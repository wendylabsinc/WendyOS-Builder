# RPi-specific image configuration
# This file is included when building for RPi machines (MACHINEOVERRIDES contains 'rpi')

inherit partuuid-rpi

# RPi-specific packages
IMAGE_INSTALL:append = " \
    packagegroup-wendyos-rpi \
    "

# Note: ext4 is kept in IMAGE_FSTYPES because Mender's mender-image-sd
# needs an ext4 rootfs for the A/B slot layout. RPi3 stays on wic-only
# via its machine-conf IMAGE_FSTYPES override.

# Remove Tegra-only packages added by tegra-image.inc or wendyos-image.bb.
# Layer separation removes these recipes from the parse tree, but IMAGE_INSTALL
# is resolved at task-scheduling time — absent packages must be explicitly removed.
IMAGE_INSTALL:remove = " \
    mender-esp \
    tegra-bootcontrol-overlay \
    packagegroup-wendyos-tegra \
    packagegroup-nvidia-container \
    nvidia-container-config \
    setup-nv-boot-control \
    usb-gadget-modules \
    usb-network-tuning \
    e2fsprogs-mke2fs \
    util-linux-mount \
    "

# WIC build dependencies
do_image_wic[depends] += " \
    rpi-cmdline:do_deploy \
    wic-tools:do_populate_sysroot \
    e2fsprogs-native:do_populate_sysroot \
    gptfdisk-native:do_populate_sysroot \
"
do_image_wic[depends] += "${PN}:do_generate_partuuids"
WIC_CREATE_EXTRA_ARGS ?= "--no-fstab-update"

# Create /config mount point directory (fstab entry is in rpi-fstab)
create_config_mountpoint() {
    mkdir -p ${IMAGE_ROOTFS}/config
}
ROOTFS_POSTPROCESS_COMMAND:append = " create_config_mountpoint;"
