# RPi-specific image configuration
# This file is included when building for RPi machines (MACHINEOVERRIDES contains 'rpi')

inherit partuuid-rpi

# RPi-specific packages
IMAGE_INSTALL:append = " \
    packagegroup-wendyos-rpi \
    "

# Remove Tegra-only packages added by tegra-image.inc or wendyos-image.bb.
# Layer separation removes these recipes from the parse tree, but IMAGE_INSTALL
# is resolved at task-scheduling time — absent packages must be explicitly removed.
IMAGE_INSTALL:remove = " \
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

# Create the /config and /data mount point directories (fstab entries are in
# rpi-fstab / rpi-wendy-fstab). The rootfs is read-only at runtime (A/B slot), so
# systemd cannot mkdir a missing mount point -- data.mount then fails on a clean
# fs and the /data bind mounts + Wendy Agent cascade-fail. wendyos-data-setup is
# dropped on RPi (see below), so /data must be created here.
create_rpi_mountpoints() {
    mkdir -p ${IMAGE_ROOTFS}/config
    mkdir -p ${IMAGE_ROOTFS}/data

    # Bind-mount targets for the persistent /data volumes (var-lib-wendy.mount,
    # var-lib-containerd.mount: /data/wendy -> /var/lib/wendy, /data/containerd ->
    # /var/lib/containerd). Those units use x-systemd.mkdir, but it only creates
    # the target on a WRITABLE fs; on the read-only A/B rootfs (and with the
    # volatile /var/lib bind skipped on blacksail systemd 259) it can't, so the
    # bind mounts fail and wendyos-agent/containerd never start. Pre-create the
    # targets so the binds succeed regardless of /var/lib writability. (Bind
    # mounts overlay these empty dirs with the /data sources.)
    mkdir -p ${IMAGE_ROOTFS}/var/lib/wendy
    mkdir -p ${IMAGE_ROOTFS}/var/lib/containerd
}

ROOTFS_POSTPROCESS_COMMAND:append = " create_rpi_mountpoints;"

# --- wendyos-update (wendy) image deltas for RPi --------------------------
# 1) Drop wendyos-data-setup (pulled by wendyos-update.inc): on RPi the /data
#    first-boot grow is done by grow-data-part (in packagegroup-wendyos-rpi).
#    wendyos-data-init only (re)formats a missing/oversized fs, so it would skip
#    the wic-preformatted ext4 data partition.
IMAGE_INSTALL:remove = "wendyos-data-setup"

# 2) wendy-stack RPi extras:
#    - wendyos-fw-env       /etc/fw_env.config so the ubootenv connector's
#                           fw_setenv reaches uboot.env on the boot FAT.
#    - wendyos-update-config pins the connector to "ubootenv".
#    - kernel-image          the boot script ext4loads /boot/${KERNEL_IMAGETYPE}
#                            from the selected rootfs slot (A/B-safe); meta-
#                            raspberrypi only deploys the kernel to the FAT.
IMAGE_INSTALL:append = " wendyos-fw-env wendyos-update-config kernel-image"

# 3) Fixed A/B rootfs sizing — the image, the A/B slot, and the .wendy OTA
#    payload are all pinned to one per-platform constant so they are identical
#    on every build and an OTA image can never outgrow its on-device slot. The
#    mechanism (floor==ceiling IMAGE_ROOTFS_SIZE/MAXSIZE + pack-time guard) lives
#    in conf/distro/include/wendyos-rootfs-size.inc (required via
#    wendyos-update.inc; WENDYOS_ROOTFS_SIZE_KB:rpi = 8 GiB), with the matching
#    `--fixed-size ${WENDYOS_ROOTFS_SIZE_KB}K` rootfsA/rootfsB slots in rpi-wendy-ab*.wks.

