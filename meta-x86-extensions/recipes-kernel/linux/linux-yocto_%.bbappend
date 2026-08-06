FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# This wildcard bbappend also matches the QEMU linux-yocto recipe. Native
# controller support is a shipping x86 guarantee here; QEMU has its own layer
# and is intentionally not pulled into the hardware contract.
WENDYOS_GAME_CONTROLLER_ENABLE = "0"
WENDYOS_GAME_CONTROLLER_ENABLE:x86-wendyos = "1"
require recipes-kernel/linux/wendy-game-controller.inc

SRC_URI:append:x86-wendyos = " \
    file://x86-nuc-drivers.cfg \
    file://x86-kernel.cfg \
    "

# Debug-only kernel config fragments, kept out of normal images and added to the
# kernel build only when WENDYOS_DEBUG=1. netconsole streams the kernel log over
# UDP for remote capture. pstore persists crash and shutdown logs to UEFI NVRAM.
# See the netconsole/pstore debug howto.
WENDYOS_X86_DEBUG_KCFG = " \
    file://netconsole.cfg \
    file://pstore.cfg \
    "
SRC_URI:append:x86-wendyos = " ${@bb.utils.contains('WENDYOS_DEBUG', '1', d.getVar('WENDYOS_X86_DEBUG_KCFG'), '', d)}"
