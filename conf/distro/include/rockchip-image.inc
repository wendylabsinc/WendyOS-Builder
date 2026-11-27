# Rockchip image configuration.
# Required from wendyos-image.bb when MACHINEOVERRIDES contains 'rockchip-wendyos'.

inherit sensor-loopback-check
inherit wendyos-links-check

# SensorLink needs both; an explicit install makes snd-aloop a requirement, not
# just a kernel-modules recommendation.
IMAGE_INSTALL:append = " v4l2loopback kernel-module-snd-aloop"

# Board firmware and hardware support, named by the machine conf.
IMAGE_INSTALL:append = " ${WENDYOS_ROCKCHIP_BOARD_PACKAGEGROUP}"

# OTA through the ubootenv connector; each slot carries its own kernel and DTB in
# /boot. /data comes from the fstab (rpi-wendy-fstab), so data-mount is dropped.
# u-boot-default-env (/etc/u-boot-initial-env) lets fw_setenv rewrite a damaged
# uboot.env instead of failing the OTA.
IMAGE_INSTALL:append = " wendyos-fw-env u-boot-default-env wendyos-update-config kernel-image kernel-devicetree"
IMAGE_INSTALL:remove = "data-mount"

# p1 carries the boot script; the loaders come from U-Boot (WKS_FILE_DEPENDS).
do_image_wic[depends] += " \
    wendyos-boot-scr:do_deploy \
    wic-tools:do_populate_sysroot \
    e2fsprogs-native:do_populate_sysroot \
    "
WIC_CREATE_EXTRA_ARGS ?= "--no-fstab-update"
WICVARS:append = " WENDYOS_CONFIG_PART_SIZE_MB"

# Pre-create /config, /data and the /data bind targets, so no mount depends on
# a directory being created at boot.
create_rockchip_mountpoints() {
    install -d -m 0755 ${IMAGE_ROOTFS}/config
    install -d -m 0755 ${IMAGE_ROOTFS}/data
    install -d -m 0755 ${IMAGE_ROOTFS}/var/lib/wendy
    install -d -m 0755 ${IMAGE_ROOTFS}/var/lib/containerd
}
ROOTFS_POSTPROCESS_COMMAND:append = " create_rockchip_mountpoints"

# The boot script is frozen at flash time (OTA rewrites only the slot), so the
# paths it loads must exist in every slot an OTA can install.
check_rockchip_boot_files() {
    for boot_file in ${KERNEL_IMAGETYPE} ${WENDYOS_ROCKCHIP_DTB}; do
        [ -f "${IMAGE_ROOTFS}/boot/$boot_file" ] || \
            bbfatal "check_rockchip_boot_files: /boot/$boot_file is missing; the boot script loads it from the slot"
    done
}
ROOTFS_POSTPROCESS_COMMAND:append = " check_rockchip_boot_files"
