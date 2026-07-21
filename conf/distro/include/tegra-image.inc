# Tegra/Jetson-specific image configuration
# This file is included when building for Tegra machines (MACHINEOVERRIDES contains 'tegra')

# (gated on MACHINEOVERRIDES containing 'tegra'). INHERIT must be set at
# config-parse time; this file is required from wendyos-image.bb (recipe
# parse), which is too late.

# Apply our UEFI boot-priority overlay during flash
TEGRA_BOOTCONTROL_OVERLAYS += "boot-priority.dtbo"

# fTPM device-tree overlay (opt-in via WENDYOS_ENABLE_TPM, off by default).
# NVIDIA ships the firmware/ftpm node status="disabled" in its DTS, so the
# tpm_ftpm_tee driver never binds and /dev/tpmrm0 is absent. tegra-ftpm-overlay
# re-emits it status="okay". The fTPM TA is already in OP-TEE for tegra264, so no
# firmware rebuild is needed there. Per SoC: only tegra264 (Thor) is validated.
# Orin (tegra234) additionally needs its own overlay + OPTEE_ENABLE_FTPM:tegra234
# = "1" (an OP-TEE rebuild) -- map WENDYOS_FTPM_DTBO:tegra234 once validated.
# Enabling a TPM has export-compliance implications on some Jetson SKUs; clear with
# compliance before shipping a TPM-enabled unit.
#
# Opt-in gate, default off (loaded here because this file is required for every
# tegra image via wendyos-image.bb). Set WENDYOS_ENABLE_TPM = "1" in local.conf to
# enable. Mirrors the x86 gate of the same name.
WENDYOS_ENABLE_TPM ?= "0"
WENDYOS_FTPM_DTBO = ""
WENDYOS_FTPM_DTBO:tegra264 = "tegra264-ftpm.dtbo"
TEGRA_BOOTCONTROL_OVERLAYS:append = "${@(' ' + d.getVar('WENDYOS_FTPM_DTBO')) if d.getVar('WENDYOS_ENABLE_TPM') == '1' and d.getVar('WENDYOS_FTPM_DTBO') else ''}"
EXTRA_IMAGEDEPENDS:append = "${@' tegra-ftpm-overlay' if d.getVar('WENDYOS_ENABLE_TPM') == '1' and d.getVar('WENDYOS_FTPM_DTBO') else ''}"

# TPM2 + LUKS2 userspace for /data encryption (gated on WENDYOS_ENABLE_TPM).
# Mirrors x86-image.inc: cryptsetup (luksFormat/open), systemd-crypt
# (systemd-cryptenroll + the boot-time systemd-cryptsetup@data), the shared
# data-crypt (first-boot enroll + crypttab), and tpm2-tools (on-device debug).
# libtss2 arrives as a systemd runtime dependency once the tpm2 PACKAGECONFIG is on.
WENDYOS_TEGRA_TPM_INSTALL = " \
    cryptsetup \
    systemd-crypt \
    data-crypt \
    tpm2-tools \
    "
IMAGE_INSTALL:append = "${@' ' + d.getVar('WENDYOS_TEGRA_TPM_INSTALL') if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"

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
