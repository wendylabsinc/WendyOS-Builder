SUMMARY = "NVIDIA open GPU kernel modules (Turing and newer, required for Blackwell / RTX 50)"
DESCRIPTION = "Builds NVIDIA's open-source GPU kernel modules (nvidia, nvidia-uvm, \
nvidia-modeset, nvidia-drm) out-of-tree against linux-yocto. Blackwell GPUs such as \
the RTX 5050 (10de:2d98) require these open modules; the matching proprietary \
userspace (libcuda/NVML, provided by nvidia-userspace) must be the same PV."
HOMEPAGE = "https://github.com/NVIDIA/open-gpu-kernel-modules"

LICENSE = "MIT | GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=1d5fa2a493e937d5a4b96e5e03b90f7c"

inherit module

# 580.105.08 is the first production driver family that knows Blackwell / RTX 50.
# Keep this in lockstep with nvidia-userspace (same PV) — kernel modules and the
# proprietary userspace must match exactly.
SRC_URI = " \
    git://github.com/NVIDIA/open-gpu-kernel-modules.git;branch=main;protocol=https \
    file://nvidia.conf \
    "
SRCREV = "2af9f1f0f7de4988432d4ae875b5858ffdb09cc2"

COMPATIBLE_MACHINE = "genericx86-64-wendyos"

# The NVIDIA kbuild finds the kernel tree via SYSSRC/SYSOUT (not KERNEL_SRC) and
# will not compile with the stack protector on. It also whitelists ARCH as
# "x86_64" (userspace naming), whereas module.bbclass exports the kernel's
# "x86" — pass x86_64 so the NVIDIA arch check passes (the kernel kbuild maps
# x86_64 back to SRCARCH=x86 internally).
#
# EXTRA_CFLAGS forces -fcf-protection=branch onto the RM core (nv-kernel.o and
# nv-modeset-kernel.o, built by NVIDIA's own make under src/, not by Kbuild).
# That build only auto-enables the flag behind a compiler probe that fails under
# the OE cross-gcc (which defaults to cf-protection=none), so the RM core shipped
# without ENDBR landing pads and faulted the kernel's IBT on CET CPUs. Forcing it
# lets the module load with CONFIG_X86_KERNEL_IBT enabled. utils.mk does
# CFLAGS += EXTRA_CFLAGS and propagates it to both src sub-makes.
MODULES_MODULE_SYMVERS_LOCATION = "kernel-open"
EXTRA_OEMAKE += " \
    ARCH='${HOST_ARCH}' \
    TARGET_ARCH='${HOST_ARCH}' \
    SYSSRC='${STAGING_KERNEL_DIR}' \
    SYSOUT='${STAGING_KERNEL_BUILDDIR}' \
    EXTRA_CFLAGS='-fcf-protection=branch' \
    "
SECURITY_STACK_PROTECTOR = ""

# Blacklist nouveau so it does not claim the GPU before nvidia loads.
do_install:append() {
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${UNPACKDIR}/nvidia.conf ${D}${sysconfdir}/modprobe.d/nvidia.conf
}

# The module class packages the .ko into kernel-module-* packages. The modprobe
# conf rides in the recipe's own package.
FILES:${PN} += "${sysconfdir}/modprobe.d/nvidia.conf"

# Autoload the compute modules at boot. The RM core is built with ENDBR
# (EXTRA_CFLAGS above), so it loads cleanly with kernel IBT enabled. drm and
# modeset are display-only and not needed for compute.
KERNEL_MODULE_AUTOLOAD += "nvidia nvidia-uvm"

RPROVIDES:${PN} += " \
    kernel-module-nvidia \
    kernel-module-nvidia-uvm \
    kernel-module-nvidia-modeset \
    kernel-module-nvidia-drm \
    "

# Runtime GSP firmware (/lib/firmware/nvidia/${PV}/gsp_*.bin) ships with
# nvidia-userspace, not here — these modules will load but not init a Blackwell
# GPU until that firmware is present.

