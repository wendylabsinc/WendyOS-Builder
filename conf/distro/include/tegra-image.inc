# Tegra/Jetson-specific image configuration
# This file is included when building for Tegra machines (MACHINEOVERRIDES contains 'tegra')

# Note: tegra-mender-setup inheritance lives in conf/distro/include/mender.inc
# (gated on MACHINEOVERRIDES containing 'tegra'). INHERIT must be set at
# config-parse time; this file is required from wendyos-image.bb (recipe
# parse), which is too late.

# Apply our UEFI boot-priority overlay during flash
TEGRA_BOOTCONTROL_OVERLAYS += "boot-priority.dtbo"

# Generate l4t.csv (NVIDIA container library mounts) from the stem manifest
# shipped by nvidia-container-config, resolved against this image's rootfs.
# Fails the build if a required CUDA/cuDNN/TensorRT library is missing,
# instead of nvidia-ctk silently skipping stale entries at boot.
inherit l4t-csv-generate

# Silence the BPMP coprocessor's serial logging. meta-tegra defaults
# TEGRA_BPMP_SERIAL_LOGGING to "1" (see tegra-bootfiles_*.bb), which
# keeps the BPMP firmware's /serial DT node alive and floods the
# shared Tegra Combined UART with "INFO: enter idle task" /
# "INFO: END TASK:MBx" messages during normal power-management cycles.
# Setting "0" makes the recipe fdtput -r the /serial node out of the
# BPMP DTB at flash-package time. Override to "1" in local.conf when
# you need BPMP-side firmware diagnostics on UART.
TEGRA_BPMP_SERIAL_LOGGING ?= "0"

# Tegra-specific packages (Jetson hardware only)
# packagegroup-wendyos-tegra pulls in tegra-bootcontrol-overlay,
# setup-nv-boot-control, packagegroup-nvidia-container, and
# conditionally tegra-uefi-capsules/bootloader-update.
# mender-esp is excluded when WENDYOS_MENDER = "0" (e.g. Thor — Mender
# deferred).
IMAGE_INSTALL:append = " \
    ${@'mender-esp' if d.getVar('WENDYOS_MENDER') == '1' else ''} \
    packagegroup-wendyos-tegra \
    gstreamer1.0-plugins-nvvideo4linux2 \
    gstreamer1.0-plugins-nvarguscamerasrc \
    gstreamer1.0-plugins-nvvidconv \
    v4l-utils \
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
