
# USB gadget kernel config fragments. Originally copied verbatim from
# the linux-jammy (5.15) tree as starting points and flagged for
# re-derivation against a 6.8 menuconfig. Verified working on 2026-05-10
# Thor hardware: tegra-xudc UDC binds at /sys/class/udc/a808670000.usb,
# usb0 NCM interface comes up cleanly. The configfs / CONFIG_USB_F_*
# symbol set survived the 5.15 → 6.8 transition intact for our use
# pattern. Drop both fragments, or re-derive, only if a future kernel
# upgrade breaks the gadget runtime.
#
# Note: the jammy bbappend (5.15) only references usb-gadget.cfg even
# though the dir ships usb-gadget-builtin.cfg too — that asymmetry is
# intentional in 5.15. For 6.8 we ship both; the builtin fragment may
# be redundant on 6.8 but doesn't hurt.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
    file://usb-gadget.cfg \
    file://usb-gadget-builtin.cfg \
    file://0001-crypto-scatterwalk-Backport-memcpy_sglist.patch \
    file://0002-crypto-algif_aead-use-memcpy_sglist-instead-of-null-skcipher.patch \
    file://0003-crypto-algif_aead-Revert-to-operating-out-of-place-CVE-2026-31431.patch \
    file://0004-crypto-algif_aead-snapshot-IV-for-async-AEAD-requests.patch \
    file://0005-crypto-algif_aead-Fix-minimum-RX-size-check-for-decryption.patch \
    file://cve-2026-46333-ptrace.patch \
    "
