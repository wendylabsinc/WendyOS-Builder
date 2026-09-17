# Qualcomm Dragonwing image configuration.
# Required from wendyos-image.bb when MACHINEOVERRIDES contains 'qcom-wendyos'.

# wendyos-image.bb pairs these with WENDYOS_USB_GADGET for every board, but both
# live in meta-tegra-extensions. IMAGE_INSTALL resolves at task-scheduling time, so
# an absent package must be removed explicitly or the build fails on it. Neither is
# needed here: the gadget stack is built into the kernel (see usb-gadget.cfg).
IMAGE_INSTALL:remove = " \
    usb-gadget-modules \
    usb-network-tuning \
    "

# The flashable output is the qcomflash package via image_types_qcom. Deliberately
# no wic/WKS_FILE: the layout comes from a partitions.conf compiled by qcom-ptool.

# wendy OTA deltas, gated on WENDYOS_OTA == "wendy".
#  - wendyos-update-config pins the OTA connector to grubenv.
#  - grub-editenv lets that connector edit EFI/BOOT/grubenv from Linux.
#  - grow-data-part is deliberately absent: the flash tool already grew /data
#    (patch0.xml rewrites the last partition's end LBA from the real disk size).
WENDYOS_QCOM_OTA_INSTALL = " \
    wendyos-update-config \
    grub-editenv \
    wendyos-config-setup \
    "

# The DTB must travel with the kernel, inside the rootfs slot. Supplied with none,
# the kernel inherits the one UEFI installs from dtb_a -- the vendor DTB for
# Qualcomm Linux's 6.6 kernel, which lacks the UFS regulator bindings this 7.2
# kernel expects, so the controller never probes and rootwait hangs forever with no
# error. In the slot rather than the ESP also keeps an OTA a single-partition write.
IMAGE_INSTALL:append = " kernel-devicetree"

# meta-qcom's kernel builds the Wi-Fi, EEPROM and Ethernet PHY modules but installs
# none of them, and each absence surfaces only as a missing interface.
IMAGE_INSTALL:append = " packagegroup-wendyos-qcom"
IMAGE_INSTALL:append = "${@' ' + d.getVar('WENDYOS_QCOM_OTA_INSTALL') if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"

# wendyos-data-setup is KEPT, unlike the wic boards (rpi/x86) which create and label
# the filesystems at image-build time. qcom-ptool only ALLOCATES partitions, so
# nothing would otherwise put a filesystem on /data -- Tegra keeps it for the same
# reason. /data is left out of qcom-wendy-fstab so the recipe's own data.mount, and
# its Requires= on the formatter, is the unit that mounts it.

# /config and /data need mount points in the rootfs to mount onto, and the /data
# bind targets must exist or the binds fail and the agent never starts.
create_wendyos_qcom_dirs() {
    install -d -m 0755 ${IMAGE_ROOTFS}/config
    install -d -m 0755 ${IMAGE_ROOTFS}/data
    install -d -m 0755 ${IMAGE_ROOTFS}/var/lib/wendy
    install -d -m 0755 ${IMAGE_ROOTFS}/var/lib/containerd
}
ROOTFS_POSTPROCESS_COMMAND:append = " create_wendyos_qcom_dirs;"

# MACHINE_FEATURES has "efi", so packagegroup-core-boot RDEPENDS ${EFI_PROVIDER}
# (unremovable) and grub-efi drops bootaa64.efi, grub.cfg and a writable grubenv
# into every rootfs slot. /boot is nofail, so an unmounted ESP would leave
# grub-editenv writing a shadow grubenv the bootloader never reads; with no payload
# there, that failure is loud instead. The real ESP is built by wendyos-esp-image.
prune_wendyos_qcom_shadow_esp() {
    rm -rf ${IMAGE_ROOTFS}/boot/EFI
}
ROOTFS_POSTPROCESS_COMMAND:append = " prune_wendyos_qcom_shadow_esp;"
