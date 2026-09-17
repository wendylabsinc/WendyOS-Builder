DESCRIPTION = "WendyOS EFI System Partition image for Qualcomm Dragonwing (GRUB A/B)"
LICENSE = "MIT"

# GRUB instead of systemd-boot. systemd-boot can only load from the ESP or
# XBOOTLDR (both FAT), so it cannot reach the kernel that ships INSIDE each ext4
# rootfs slot -- after an OTA the new rootfs would boot the stale ESP kernel
# unless the OTA also rewrote the ESP. GRUB's ext2 module reads ext4, so it loads
# /boot/Image out of the selected slot and the kernel travels with the rootfs,
# keeping an OTA a single raw partition write.
PACKAGE_INSTALL = " \
    grub-efi \
    wendyos-grub-ab \
"

inherit image features_check

# vfat, 512 MiB pinned floor==ceiling, and the UFS-compatible sector size. Reused
# from meta-qcom rather than restated; the path is layer-root-relative because
# BBPATH carries every layer root (same idiom as the require lines in
# conf/distro/wendyos.conf).
require recipes-kernel/images/esp-qcom-common.inc

# EFI_BOOT_IMAGE / EFI_FILES_PATH come from oe-core's conf/image-uefi.conf, which
# is not globally included (only the systemd-boot/grub-efi/uki/barebox classes
# require it). Without this the checks below compare against empty strings and the
# fatal fires on every build. Same require line grub-efi.bbclass uses.
require conf/image-uefi.conf

# Matches the 512 MiB "efi" partition in
# meta-qcom-extensions/recipes-bsp/partition/files/partitions.conf.
REQUIRED_MACHINE_FEATURES = "efi"
COMPATIBLE_MACHINE = "iq-8275-evk-wendyos"

# FAT volume label "boot". Not cosmetic: qcom-wendy-fstab mounts the ESP as
# LABEL=boot, and the wendyos-update grubenv connector REFUSES to write A/B state
# unless /boot is a real mountpoint (assertEnvWritable, guarding against writing a
# shadow grubenv the bootloader never reads). Without the label the ESP never
# mounts and every OTA declines to arm a trial. Observed on hardware: blkid
# reported TYPE="vfat" PARTLABEL="efi" but no LABEL, and /boot was unmounted.
# `-n` is passed straight to mkfs.vfat (IMAGE_CMD:vfat = "oe_mkvfatfs
# ${EXTRA_IMAGECMD}"); upstream's include already appends -S for the sector size.
EXTRA_IMAGECMD:vfat += " -n boot"

# grub-efi packages its loader under ${EFI_FILES_PATH} (= /boot/EFI/BOOT), because
# EFI_PREFIX defaults to /boot for a package installed into a rootfs. The ESP
# image IS the partition, so /boot/EFI has to become /EFI at its root. Mirrors
# esp-qcom-image.bb's setup_efi_folder, and the trailing prune drops the rest of
# the package's rootfs (docs, /usr/lib/grub modules) that has no business on a
# 512 MiB boot partition -- the modules grub.cfg needs are built into
# bootaa64.efi (see the grub-efi bbappend).
setup_efi_folder() {
    if [ -d ${IMAGE_ROOTFS}/boot/EFI ]; then
        install -d ${IMAGE_ROOTFS}/EFI
        cp -a ${IMAGE_ROOTFS}/boot/EFI/. ${IMAGE_ROOTFS}/EFI/
    fi

    if [ ! -f ${IMAGE_ROOTFS}/EFI/BOOT/${EFI_BOOT_IMAGE} ]; then
        bbfatal "wendyos-esp-image: ${EFI_BOOT_IMAGE} missing from the ESP tree. grub-efi only names its loader ${EFI_BOOT_IMAGE} when EFI_PROVIDER = \"grub-efi\"; the machine conf must set that (upstream qcom-common.inc defaults it to systemd-boot, which makes grub build as grub-efi-${EFI_BOOT_IMAGE} instead)."
    fi
    for f in grub.cfg grubenv; do
        if [ ! -f ${IMAGE_ROOTFS}/EFI/BOOT/${f} ]; then
            bbfatal "wendyos-esp-image: EFI/BOOT/${f} missing from the ESP tree (expected from wendyos-grub-ab)"
        fi
    done

    find ${IMAGE_ROOTFS} -mindepth 1 ! -path "${IMAGE_ROOTFS}/EFI*" -exec rm -rf {} +
}
IMAGE_PREPROCESS_COMMAND:append = " setup_efi_folder"
