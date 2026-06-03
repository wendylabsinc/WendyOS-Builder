# Generic x86_64 PC image configuration.

# Size is in KB. Override from local.conf for larger PC disk images.
WENDYOS_X86_ROOTFS_SIZE ??= "8388608"
IMAGE_ROOTFS_SIZE:x86-wendyos = "${WENDYOS_X86_ROOTFS_SIZE}"

# Useful on commodity PCs and harmless on machines without a given bus/device.
IMAGE_INSTALL:append = " \
    pciutils \
    linux-firmware \
    "

# Experimental NVIDIA dGPU container plumbing. This does not ship proprietary
# desktop GPU drivers; it generates CDI metadata only when a driver and
# nvidia-ctk are present.
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_NVIDIA_DGPU') == '1', ' nvidia-dgpu-cdi', '')} \
    "
