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

# CVE-2026-31431 (crypto/algif_aead AAD in-place corruption) — only needed on
# scarthgap's linux-yocto 6.6 (LINUX_VERSION 6.6.111, pre-6.6.137). wrynose
# ships 6.18.24 which already contains the fix natively (mainline pre-6.15).
SRC_URI += "${@' \
    file://0001-crypto-scatterwalk-Backport-memcpy_sglist.patch \
    file://0002-crypto-algif_aead-use-memcpy_sglist-instead-of-null-skcipher.patch \
    file://0003-crypto-algif_aead-Revert-to-operating-out-of-place-CVE-2026-31431.patch \
    file://0004-crypto-algif_aead-snapshot-IV-for-async-AEAD-requests.patch \
    file://0005-crypto-algif_aead-Fix-minimum-RX-size-check-for-decryption.patch \
' if d.getVar('PV').startswith('6.6.') else ''}"
