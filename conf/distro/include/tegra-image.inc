# Tegra/Jetson-specific image configuration
# This file is included when building for Tegra machines (MACHINEOVERRIDES contains 'tegra')

# Apply our UEFI boot-priority overlay during flash
TEGRA_BOOTCONTROL_OVERLAYS += "boot-priority.dtbo"

# Tegra-specific packages (Jetson hardware only)
# packagegroup-wendyos-tegra pulls in tegra-bootcontrol-overlay,
# setup-nv-boot-control, packagegroup-nvidia-container, and
# conditionally tegra-uefi-capsules/bootloader-update.
# mender-esp is excluded on Thor (tegra264) — Mender on Thor is deferred
# (see wendyos.conf:16-19).
IMAGE_INSTALL:append = " \
    ${@'' if 'tegra264' in d.getVar('MACHINEOVERRIDES').split(':') else 'mender-esp'} \
    packagegroup-wendyos-tegra \
    gstreamer1.0-plugins-nvvideo4linux2 \
    "

# Enable DeepStream SDK support (optional - adds ~1GB to image)
# Tegra/NVIDIA hardware only - DeepStream requires NVIDIA GPUs
# Also enables l4t-deepstream.csv which provides:
# - GPU device nodes (/dev/nvhost-*) for tegrastats and GPU monitoring
# - CUDA compilation toolchain (headers, binaries, nvvm) for Triton/JIT
# - Additional libraries (libnuma) and monitoring paths
WENDYOS_USB_GADGET ?= "1"
WENDYOS_DEEPSTREAM ?= "1"
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse( \
        d.getVar('WENDYOS_DEEPSTREAM') == '1', \
            ' \
                deepstream-7.1 \
            ', \
            '' \
        )} \
    "
