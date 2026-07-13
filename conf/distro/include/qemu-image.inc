# QEMU-specific image configuration
# This file is included when building for QEMU machines (MACHINEOVERRIDES contains 'qemuall')

# QEMU rootfs size configuration (in KB)
# Override in local.conf: QEMU_ROOTFS_SIZE = "1048576"  # 1GB
# Override in local.conf: QEMU_ROOTFS_SIZE = "2097152"  # 2GB
# Override in local.conf: QEMU_ROOTFS_SIZE = "4194304"  # 4GB
QEMU_ROOTFS_SIZE ??= "4194304"
IMAGE_ROOTFS_SIZE:qemuall = "${QEMU_ROOTFS_SIZE}"
IMAGE_ROOTFS_EXTRA_SPACE:qemuall = "0"

# Remove packages not needed for QEMU
# USB gadget packages are conditionally added via WENDYOS_USB_GADGET variable
IMAGE_INSTALL:remove = " \
    gadget-setup \
    usb-gadget-modules \
    usb-network-tuning \
    "

# Add QEMU-specific packages
# - udev-qemu-usb0: Rename virtio-net to usb0 for NetworkManager compatibility
IMAGE_INSTALL:append = " \
    udev-qemu-usb0 \
    "
