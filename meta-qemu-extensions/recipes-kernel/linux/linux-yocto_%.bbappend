# Extend COMPATIBLE_MACHINE to include qemuarm64-wendyos
# Base recipe restricts to specific QEMU machine names with exact regex match
COMPATIBLE_MACHINE:append = "|qemuarm64-wendyos"

# Use qemuarm64 BSP definition for kernel configuration
# linux-yocto looks for machine-specific kernel metadata, tell it to use qemuarm64
KMACHINE:qemuarm64-wendyos = "qemuarm64"

# CVE-2026-46333 (ssh-keysign-pwn): no patch needed, the fix is already in the
# kernel oe-core builds. Upstream 2a93a4fac7b6 ("ptrace: slightly saner
# get_dumpable() logic") is an ancestor of SRCREV_machine:qemuarm64 (9eb7db13,
# linux-yocto 6.18.39), and kernel/ptrace.c there already defines
# task_still_dumpable(). Applying our backport on top fails do_patch:
# kgit-s2q tries git am, git am -C1 and git apply --index -C1, all of which
# reject an already-applied patch, and kernel-yocto.bbclass turns that into
# "Could not apply patches for qemuarm64".
#
# We only ever built this bbappend against scarthgap's 6.6 kernel, where the
# backport was genuinely missing, so the clash surfaced the moment qemu-arm64
# moved to blacksail. If a future kernel ever regresses, re-add a patch under
# recipes-kernel/linux/linux-yocto/, a SRC_URI line for it and the
# FILESEXTRAPATHS:prepend line that puts that directory on the file search path.
