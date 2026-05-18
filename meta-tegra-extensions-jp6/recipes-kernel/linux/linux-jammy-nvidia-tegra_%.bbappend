
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
    file://usb-gadget.cfg \
    file://0001-crypto-scatterwalk-Backport-memcpy_sglist.patch \
    file://0002-crypto-algif_aead-use-memcpy_sglist-instead-of-null-skcipher.patch \
    file://0003-crypto-algif_aead-Revert-to-operating-out-of-place-CVE-2026-31431.patch \
    file://0004-crypto-algif_aead-snapshot-IV-for-async-AEAD-requests.patch \
    file://0005-crypto-algif_aead-Fix-minimum-RX-size-check-for-decryption.patch \
    file://cve-2026-46333-ptrace.patch \
    "

# file://enable_efi_stub.cfg
