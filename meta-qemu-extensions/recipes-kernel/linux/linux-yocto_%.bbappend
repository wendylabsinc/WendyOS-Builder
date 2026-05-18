# Extend COMPATIBLE_MACHINE to include qemuarm64-wendyos
# Base recipe restricts to specific QEMU machine names with exact regex match
COMPATIBLE_MACHINE:append = "|qemuarm64-wendyos"

# Use qemuarm64 BSP definition for kernel configuration
# linux-yocto looks for machine-specific kernel metadata, tell it to use qemuarm64
KMACHINE:qemuarm64-wendyos = "qemuarm64"

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# CVE-2026-46333 (ssh-keysign-pwn): per-version stable backport. scarthgap ships
# linux-yocto 6.6, wrynose ships 6.18 — select by PV major.minor.
SRC_URI += "file://cve-2026-46333-ptrace-${@'.'.join(d.getVar('PV').split('.')[:2])}.patch"
