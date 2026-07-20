FILESEXTRAPATHS:prepend := "${THISDIR}/linux-raspberrypi:"

# Add container support kernel config when WENDYOS_CONTAINER_RUNTIME is enabled
SRC_URI:append:rpi = "${@' file://container.cfg' if d.getVar('WENDYOS_CONTAINER_RUNTIME') == '1' else ''}"

# Add USB gadget kernel config when WENDYOS_USB_GADGET is enabled
SRC_URI:append:rpi = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"

# Add systemd-sysext filesystem prerequisites when driver add-ons are enabled
SRC_URI:append:rpi = "${@' file://sysext.cfg' if d.getVar('WENDYOS_DRIVER_EXTENSIONS') == '1' else ''}"

# Bake in the common USB-serial bridge chips (=y) so they bind on hotplug without
# relying on module auto-load — the most common host peripherals (Arduino/ESP/GPS).
SRC_URI:append:rpi = " file://usb-serial.cfg"

# Bake in common USB Ethernet adapters + removable-media filesystems (=y) so USB
# NICs and exFAT/NTFS drives work on hotplug without module auto-load.
SRC_URI:append:rpi = " file://usb-peripherals.cfg"
SRC_URI += "file://0001-dwc2-force-g_dma-false-for-BCM2712-in-peripheral-mod.patch"

# CVE backports below are 6.6.y stable backports — they apply to (and are only
# needed on) the 6.6 kernel that the scarthgap meta-raspberrypi ships. Newer
# kernels already carry these fixes upstream and the 6.6-context patches do NOT
# apply (e.g. blacksail's meta-raspberrypi defaults to 6.12, where the
# crypto/algif_aead series fails do_patch). Gate on the kernel major.minor so
# the same bbappend works on both trees.
#   NOTE: this assumes the CVEs are already fixed in the newer kernel (true for
#   these 6.6.y stable backports vs the 6.12.y LTS). If a future kernel is NOT
#   yet patched, ship a matching backport under its own gate.
WENDYOS_RPI_KERNEL_66 = "${@'1' if (d.getVar('PV') or '').startswith('6.6.') else '0'}"

# CVE-2026-46333 (ssh-keysign-pwn).
SRC_URI:append = "${@' file://cve-2026-46333-ptrace.patch' if d.getVar('WENDYOS_RPI_KERNEL_66') == '1' else ''}"

# CVE-2026-31431 (crypto/algif_aead AAD in-place corruption) — 6.6.y series.
WENDYOS_RPI_CVE_31431 = " \
    file://0001-crypto-scatterwalk-Backport-memcpy_sglist.patch \
    file://0002-crypto-algif_aead-use-memcpy_sglist-instead-of-null-skcipher.patch \
    file://0003-crypto-algif_aead-Revert-to-operating-out-of-place-CVE-2026-31431.patch \
    file://0004-crypto-algif_aead-snapshot-IV-for-async-AEAD-requests.patch \
    file://0005-crypto-algif_aead-Fix-minimum-RX-size-check-for-decryption.patch \
    "

SRC_URI:append = "${@' ' + d.getVar('WENDYOS_RPI_CVE_31431') if d.getVar('WENDYOS_RPI_KERNEL_66') == '1' else ''}"

