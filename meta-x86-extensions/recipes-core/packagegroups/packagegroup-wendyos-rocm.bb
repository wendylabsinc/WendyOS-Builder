SUMMARY = "WendyOS ROCm runtime package group"
DESCRIPTION = "Feed target for optional ROCm runtime support on validated x86 AMD GPUs and APUs"
LICENSE = "MIT"

PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

COMPATIBLE_MACHINE = "(genericx86-64-wendyos)"

# This packagegroup is intentionally not installed in the base image. It is the
# package name requested by the x86 driver updater when a WendyOS driver feed
# provides a validated ROCm stack for the running kernel and hardware.
#
# WendyOS-Builder does not provide ROCm recipes yet. Keep the default empty so
# this layer remains buildable; a ROCm driver feed layer should override this
# with package names such as rocm-core, rocminfo, and rocm-hip-runtime.
WENDYOS_ROCM_RUNTIME_PACKAGES ??= ""

RRECOMMENDS:${PN} = "${WENDYOS_ROCM_RUNTIME_PACKAGES}"
