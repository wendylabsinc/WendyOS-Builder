DESCRIPTION = "WendyOS live installer image for generic x86_64 PCs"
LICENSE = "MIT"

# wendyos-image.bb lives in the base wendyos layer; reference it by its
# layer-relative path so BBPATH resolves it now that this recipe sits in
# meta-x86-extensions (a bare "wendyos-image.bb" only worked when co-located).
require recipes-core/images/wendyos-image.bb

# The production WendyOS x86 image remains a directly flashable .wic. This
# recipe builds a live ISO that exposes OE-Core's "install" boot entry, which
# partitions an internal disk and copies the live root filesystem onto it.
IMAGE_BASENAME = "wendyos-installer-image"
IMAGE_FSTYPES = "iso"

# ISO can carry the large ext4 rootfs.img. hddimg uses FAT and cannot hold the
# current WendyOS rootfs once it grows beyond 4 GiB.
LIVE_ROOTFS_TYPE = "ext4"
LABELS_LIVE = "boot install"
INITRD_IMAGE_LIVE = "core-image-minimal-initramfs"
EFI_PROVIDER ?= "grub-efi"

BOOTIMG_VOLUME_ID = "WENDYOSINST"
SYSLINUX_PROMPT = "1"
SYSLINUX_TIMEOUT = "100"
SYSTEMD_BOOT_TIMEOUT = "10"
