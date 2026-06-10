# Generic x86_64 PC image configuration.

# Size is in KB. Override from local.conf for larger PC disk images.
WENDYOS_X86_ROOTFS_SIZE ??= "8388608"
IMAGE_ROOTFS_SIZE:x86-wendyos = "${WENDYOS_X86_ROOTFS_SIZE}"

# x86 installer images can optionally install driver updates from a WendyOS
# package feed after first boot. Keep runtime package management only on this
# target; embedded/OTA-oriented targets keep the default immutable behavior.
WENDYOS_ENABLE_PACKAGE_MANAGEMENT:x86-wendyos ?= "1"
WENDYOS_SSHD:x86-wendyos ?= "1"

WENDYOS_DRIVER_FEED_URI ??= ""
WENDYOS_DRIVER_FEED_GPGCHECK ??= "0"
WENDYOS_NVIDIA_DRIVER_PACKAGE ??= "packagegroup-wendyos-nvidia-graphics"
WENDYOS_ROCM_DRIVER_PACKAGE ??= "packagegroup-wendyos-rocm"

# Useful on commodity PCs and harmless on machines without a given bus/device.
IMAGE_INSTALL:append = " \
    pciutils \
    linux-firmware \
    ca-certificates \
    wendyos-driver-installer \
    "

# Experimental NVIDIA dGPU container plumbing. This does not ship proprietary
# desktop GPU drivers; it generates CDI metadata only when a driver and
# nvidia-ctk are present.
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_NVIDIA_DGPU') == '1', ' nvidia-dgpu-cdi', '')} \
    "

configure_wendyos_driver_feed() {
    install -d ${IMAGE_ROOTFS}${libdir}/wendyos
    cat > ${IMAGE_ROOTFS}${libdir}/wendyos/driver-installer.conf <<EOF
WENDYOS_NVIDIA_DRIVER_PACKAGE="${WENDYOS_NVIDIA_DRIVER_PACKAGE}"
WENDYOS_ROCM_DRIVER_PACKAGE="${WENDYOS_ROCM_DRIVER_PACKAGE}"
EOF

    if [ -n "${WENDYOS_DRIVER_FEED_URI}" ]; then
        install -d ${IMAGE_ROOTFS}${sysconfdir}/yum.repos.d
        cat > ${IMAGE_ROOTFS}${sysconfdir}/yum.repos.d/wendyos-drivers.repo <<EOF
[wendyos-drivers]
name=WendyOS x86 driver updates
baseurl=${WENDYOS_DRIVER_FEED_URI}
enabled=1
gpgcheck=${WENDYOS_DRIVER_FEED_GPGCHECK}
EOF
    fi
}
ROOTFS_POSTPROCESS_COMMAND:append:x86-wendyos = " configure_wendyos_driver_feed;"
