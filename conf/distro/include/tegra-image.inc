# Tegra/Jetson-specific image configuration
# This file is included when building for Tegra machines (MACHINEOVERRIDES contains 'tegra')

# (gated on MACHINEOVERRIDES containing 'tegra'). INHERIT must be set at
# config-parse time; this file is required from wendyos-image.bb (recipe
# parse), which is too late.

# Apply our UEFI boot-priority overlay during flash
TEGRA_BOOTCONTROL_OVERLAYS += "boot-priority.dtbo"

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
IMAGE_INSTALL:append = " \
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
# The DeepStream package is BSP-specific:
#   blacksail (JP7.2/r39.2, CUDA 13) -> deepstream-8.0 (meta-tegra-extensions-jp7)
#   scarthgap (JP6, CUDA 12)         -> deepstream-7.1 (meta-tegra-community)
#   wrynose (r38.4) / other          -> none (no DeepStream recipe exists there)
DEEPSTREAM_PKG = "${@'deepstream-8.0' if d.getVar('WENDYOS_LAYER_TREE') == 'blacksail' else ('deepstream-7.1' if d.getVar('WENDYOS_LAYER_TREE') == 'scarthgap' else '')}"
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse( \
        d.getVar('WENDYOS_DEEPSTREAM') == '1', \
            d.getVar('DEEPSTREAM_PKG'), \
            '' \
        )} \
    "
