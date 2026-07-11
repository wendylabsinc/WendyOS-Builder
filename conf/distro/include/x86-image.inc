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
# packagegroup-wendyos-x86 (meta-x86-extensions) carries the NUC network/BT/GPU
# kernel-module coverage as RRECOMMENDS.
IMAGE_INSTALL:append = " \
    pciutils \
    linux-firmware \
    ca-certificates \
    wendyos-driver-installer \
    packagegroup-wendyos-x86 \
    "

# NVIDIA dGPU compute stack. When WENDYOS_NVIDIA_DGPU=1 this bakes the full
# driver stack into the image for validation: the open kernel modules, the
# matching proprietary userspace, the container toolkit and the CDI helper.
# Baking the proprietary userspace into a shipped image is a licensing question,
# so this is the validation path. The shipping path installs the same
# packagegroup from the driver feed at first boot (wendyos-driver-installer),
# tracked as a separate follow-up.
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_NVIDIA_DGPU') == '1', 'packagegroup-wendyos-nvidia-graphics', '')} \
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

# /config and /data as plain rootfs directories, not partitions. x86 has a
# single persistent read-write rootfs (no A/B), so these persist as-is and no
# /data machinery is wired (wendyos-etc-binds/data-setup are OTA-only and stay
# off — that is deliberate). They mirror the fleet paths and, being directories,
# become drop-in mount points if x86 ever gains wendy-update A/B: add the
# partitions + fstab and migrate the folder contents before enabling the mount.
create_wendyos_dirs() {
    install -d -m 0755 ${IMAGE_ROOTFS}/config
    install -d -m 0755 ${IMAGE_ROOTFS}/data
}

ROOTFS_POSTPROCESS_COMMAND:append:x86-wendyos = " create_wendyos_dirs;"

# NVIDIA's prebuilt userspace binaries (nvidia-smi, nvidia-modprobe) use the
# x86-64 ABI loader path /lib64/ld-linux-x86-64.so.2, but OE only provides /lib.
# Add a /lib64 -> lib compat symlink so they execute. Gated on the NVIDIA stack
# so non-NVIDIA x86 images are untouched.
create_lib64_compat() {
    [ -e ${IMAGE_ROOTFS}/lib64 ] || ln -sf lib ${IMAGE_ROOTFS}/lib64
}

ROOTFS_POSTPROCESS_COMMAND:append:x86-wendyos = " ${@oe.utils.ifelse(d.getVar('WENDYOS_NVIDIA_DGPU') == '1', 'create_lib64_compat;', '')}"
