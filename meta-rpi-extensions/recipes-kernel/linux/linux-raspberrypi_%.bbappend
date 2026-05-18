FILESEXTRAPATHS:prepend := "${THISDIR}/linux-raspberrypi:"

# Add container support kernel config when WENDYOS_CONTAINER_RUNTIME is enabled
SRC_URI:append:rpi = "${@' file://container.cfg' if d.getVar('WENDYOS_CONTAINER_RUNTIME') == '1' else ''}"

# Add USB gadget kernel config when WENDYOS_USB_GADGET is enabled
SRC_URI:append:rpi = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"
SRC_URI += "file://0001-dwc2-force-g_dma-false-for-BCM2712-in-peripheral-mod.patch"

# CVE-2026-46333 (ssh-keysign-pwn) — only the 6.6 backport is shipped because
# meta-raspberrypi's PREFERRED_VERSION_linux-raspberrypi is "6.6.%". If a future
# config bumps the rpi kernel to 6.1 / 6.12, ship the matching stable backport.
SRC_URI:append = " file://cve-2026-46333-ptrace.patch"

# CVE-2026-31431 (crypto/algif_aead AAD in-place corruption) — 6.6.y backport
# series; same scope assumption as above (PREFERRED_VERSION is 6.6.%).
SRC_URI += " \
    file://0001-crypto-scatterwalk-Backport-memcpy_sglist.patch \
    file://0002-crypto-algif_aead-use-memcpy_sglist-instead-of-null-skcipher.patch \
    file://0003-crypto-algif_aead-Revert-to-operating-out-of-place-CVE-2026-31431.patch \
    file://0004-crypto-algif_aead-snapshot-IV-for-async-AEAD-requests.patch \
    file://0005-crypto-algif_aead-Fix-minimum-RX-size-check-for-decryption.patch \
    "

