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

# --- wendyos-update (wendy) image deltas for RPi --------------------------
# All gated on WENDYOS_OTA == "wendy" so RPi3/4 (Mender) are unaffected; RPi5
# moves to the wendy stack (raspberrypi5-wendyos.conf sets WENDYOS_OTA="wendy").
#
# 1) Drop wendyos-data-setup (pulled by wendyos-update.inc): on RPi the /data
#    first-boot grow is done by grow-data-part (in packagegroup-wendyos-rpi).
#    wendyos-data-init only (re)formats a missing/oversized fs, so it would skip
#    the wic-preformatted ext4 data partition.
IMAGE_INSTALL:remove = "${@'wendyos-data-setup' if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"

# 2) wendy-stack RPi extras:
#    - wendyos-fw-env       /etc/fw_env.config so the ubootenv connector's
#                           fw_setenv reaches uboot.env on the boot FAT.
#    - wendyos-update-config pins the connector to "ubootenv".
#    - kernel-image          the boot script ext4loads /boot/${KERNEL_IMAGETYPE}
#                            from the selected rootfs slot (A/B-safe); meta-
#                            raspberrypi only deploys the kernel to the FAT.
IMAGE_INSTALL:append = "${@' wendyos-fw-env wendyos-update-config kernel-image' if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"
