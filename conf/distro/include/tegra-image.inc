# Tegra/Jetson-specific image configuration
# This file is included when building for Tegra machines (MACHINEOVERRIDES contains 'tegra')

# Note: tegra-mender-setup inheritance lives in conf/distro/include/mender.inc
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
# mender-esp is included only for WENDYOS_OTA = "mender" (Mender-specific).
IMAGE_INSTALL:append = " \
    ${@'mender-esp' if d.getVar('WENDYOS_OTA') == 'mender' else ''} \
    packagegroup-wendyos-tegra \
    gstreamer1.0-plugins-nvvideo4linux2 \
    gstreamer1.0-plugins-nvarguscamerasrc \
    gstreamer1.0-plugins-nvvidconv \
    v4l-utils \
    "

# GRUB2 A/B boot stack (WENDYOS_TEGRA_GRUB_AB = 1, set per NVMe Orin machine;
# default OFF here). Swaps Orin's boot path from NVIDIA UEFI/L4TLauncher +
# nvbootctrl A/B (whose RootfsRedundancyLevel is unarmable from the OS on Orin)
# to a GRUB2 EFI payload on the ESP that selects the A/B rootfs slot from an
# OS-writable grubenv:
#   wendyos-grub                  grubaa64.efi + grub.cfg + grubenv (staged to ESP)
#   wendyos-grub-firstboot        stage to ESP + enroll BootOrder (L4TLauncher kept)
#   wendyos-update-config-grubenv pin the grubenv connector (not tegrauefi)
#   efibootmgr                    BootOrder enroll tool the first-boot service uses
#   grub-editenv                  runtime grubenv editor the grubenv connector uses
# L4TLauncher stays enrolled as the fallback boot path. tegra-rootfs-redundancy
# is dropped from the packagegroup on this path (its firmware A/B mechanism is
# unused and unarmable on Orin).
IMAGE_INSTALL:append = " \
    ${@'wendyos-grub wendyos-grub-firstboot wendyos-update-config-grubenv efibootmgr grub-editenv' if (d.getVar('WENDYOS_TEGRA_GRUB_AB') or '0') == '1' else ''} \
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
