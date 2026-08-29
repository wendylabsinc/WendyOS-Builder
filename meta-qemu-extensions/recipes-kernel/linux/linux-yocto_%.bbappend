# Extend COMPATIBLE_MACHINE to include qemuarm64-wendyos
# Base recipe restricts to specific QEMU machine names with exact regex match
COMPATIBLE_MACHINE:append = "|qemuarm64-wendyos"

# Use qemuarm64 BSP definition for kernel configuration
# linux-yocto looks for machine-specific kernel metadata, tell it to use qemuarm64
KMACHINE:qemuarm64-wendyos = "qemuarm64"

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# ACPI, required to boot through UEFI: the qemuarm64 BSP is DTB-only, which is
# right for -kernel but leaves the kernel unable to find the GIC, the PL011 or
# virtio-blk when firmware describes the platform.
SRC_URI:append:qemuall = " file://vm-kernel.cfg"

# No CVE-2026-46333 backport here: upstream 2a93a4fac7b6 ("ptrace: slightly
# saner get_dumpable() logic") is already an ancestor of the kernel oe-core
# builds, and kgit-s2q fails do_patch outright on an already-applied patch.
# Should a kernel ever regress, a patch under linux-yocto/ plus a SRC_URI line
# is all it takes -- FILESEXTRAPATHS above already covers the search path.
