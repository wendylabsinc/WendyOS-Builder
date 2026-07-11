# Generic x86_64 PC image configuration.

# Size is in KB. Override from local.conf for larger PC disk images.
WENDYOS_X86_ROOTFS_SIZE ??= "8388608"
IMAGE_ROOTFS_SIZE:x86-wendyos = "${WENDYOS_X86_ROOTFS_SIZE}"

# x86 is a PC-class target, so keep runtime package management and sshd enabled.
# Embedded/OTA-oriented targets keep the default immutable behavior. Package
# management also underpins the future GPU userspace feed (Phase B, see the plan
# doc).
WENDYOS_ENABLE_PACKAGE_MANAGEMENT:x86-wendyos ?= "1"
WENDYOS_SSHD:x86-wendyos ?= "1"

# Useful on commodity PCs and harmless on machines without a given bus/device.
# packagegroup-wendyos-x86 (meta-x86-extensions) carries the NUC network/BT/GPU
# kernel-module coverage as RRECOMMENDS.
IMAGE_INSTALL:append = " \
    pciutils \
    linux-firmware \
    ca-certificates \
    packagegroup-wendyos-x86 \
    "

# NVIDIA dGPU compute stack. When WENDYOS_NVIDIA_DGPU=1 this bakes the full
# driver stack into the image: the open kernel modules, the matching proprietary
# userspace, the container toolkit and the wendyos-gpu-cdi detect/CDI helper.
# Baking the proprietary userspace into a shipped image is a licensing question,
# so this is the current path (Phase A). The shipping path (Phase B) keeps the
# kernel modules baked and moves the userspace to a feed installed at first boot
# by the detect service. See docs/plans/x86-support-plan.md.
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_NVIDIA_DGPU') == '1', 'packagegroup-wendyos-nvidia-graphics', '')} \
    "

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
