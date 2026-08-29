# QEMU-specific image configuration
# This file is included when building for QEMU machines (MACHINEOVERRIDES contains 'qemuall')

# Rootfs size in KB. Override in local.conf, e.g. "6291456" for 6 GiB.
QEMU_ROOTFS_SIZE ??= "4194304"

# Pin the rootfs the way every other board does, so the ext4 and the wks rootfs
# partition match exactly and outgrowing it fails loudly. WENDYOS_ROOTFS_SIZE_KB
# also gates the extra-space append in wendyos-image.bb, which would otherwise
# push the image past that ceiling.
WENDYOS_ROOTFS_SIZE_KB:qemuall = "${QEMU_ROOTFS_SIZE}"
require conf/distro/include/wendyos-rootfs-size.inc

# Belt and braces: wendyos-image.bb already gates these on WENDYOS_USB_GADGET,
# which is 0 for every QEMU machine.
IMAGE_INSTALL:remove = " \
    gadget-setup \
    usb-gadget-modules \
    usb-network-tuning \
    "

# kernel-image puts /boot/Image in the rootfs so GRUB loads it from there,
# keeping the ESP independent of the rootfs. No grub-editenv: without A/B OTA
# there is no grubenv to edit.
#
# grow-data-part expands /data into whatever disk size the launcher created,
# which is why the wks puts /data last.
IMAGE_INSTALL:append = " \
    kernel-image \
    grow-data-part \
    "

# wic's generated fstab would append a /boot entry hard-coded to vda,
# duplicating the LABEL=boot line vm-fstab already provides.
WIC_CREATE_EXTRA_ARGS ?= "--no-fstab-update"
do_image_wic[depends] += " \
    wic-tools:do_populate_sysroot \
    e2fsprogs-native:do_populate_sysroot \
    gptfdisk-native:do_populate_sysroot \
    "

# /config and /data are real partitions, so the rootfs must carry the empty
# directories for those mounts to land on.
create_wendyos_vm_dirs() {
    install -d -m 0755 ${IMAGE_ROOTFS}/config
    install -d -m 0755 ${IMAGE_ROOTFS}/data
}

ROOTFS_POSTPROCESS_COMMAND:append:qemuall = " create_wendyos_vm_dirs;"
