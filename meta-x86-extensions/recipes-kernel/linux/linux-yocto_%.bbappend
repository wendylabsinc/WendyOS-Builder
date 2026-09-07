FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:x86-wendyos = " \
    file://x86-nuc-drivers.cfg \
    file://x86-kernel.cfg \
    "

# TPM 2.0 kernel drivers, only when the TPM stack is enabled (WENDYOS_ENABLE_TPM).
# See conf/template/include/local/x86.inc and docs/plans/x86-security.md.
SRC_URI:append:x86-wendyos = "${@bb.utils.contains('WENDYOS_ENABLE_TPM', '1', ' file://x86-tpm.cfg', '', d)}"

# Debug-only kernel config fragments, kept out of normal images and added to the
# kernel build only when WENDYOS_DEBUG=1. netconsole streams the kernel log over
# UDP for remote capture. pstore persists crash and shutdown logs to UEFI NVRAM.
# See the netconsole/pstore debug howto.
WENDYOS_X86_DEBUG_KCFG = " \
    file://netconsole.cfg \
    file://pstore.cfg \
    "
SRC_URI:append:x86-wendyos = " ${@bb.utils.contains('WENDYOS_DEBUG', '1', d.getVar('WENDYOS_X86_DEBUG_KCFG'), '', d)}"

# SocketCAN: core, protocols and the USB/SPI adapter drivers. The shared fragment
# sets every symbol it needs explicitly -- including CONFIG_SPI, which the
# genericx86-64 config chain does not otherwise enable and which the two MCP251x
# drivers depend on -- so the result does not depend on what the linux-yocto
# standard config happens to carry.
require ${@'recipes-kernel/linux/can.inc' if d.getVar('WENDYOS_CAN') == '1' else ''}
