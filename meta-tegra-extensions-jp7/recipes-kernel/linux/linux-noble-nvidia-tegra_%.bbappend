
# USB gadget kernel config fragments. Originally copied verbatim from
# the linux-jammy (5.15) tree as starting points and flagged for
# re-derivation against a 6.8 menuconfig. Verified working on 2026-05-10
# Thor hardware: tegra-xudc UDC binds at /sys/class/udc/a808670000.usb,
# usb0 NCM interface comes up cleanly. The configfs / CONFIG_USB_F_*
# symbol set survived the 5.15 → 6.8 transition intact for our use
# pattern. Drop both fragments, or re-derive, only if a future kernel
# upgrade breaks the gadget runtime.
#
# Note: both usb-gadget.cfg and usb-gadget-builtin.cfg are shipped for 6.8.
# The builtin one may be redundant here, but it does no harm.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

require ${@'recipes-kernel/linux/game-controller.inc' if d.getVar('WENDYOS_GAME_CONTROLLER') == '1' else ''}

SRC_URI += " \
    file://usb-gadget.cfg \
    file://usb-gadget-builtin.cfg \
    file://usb-serial.cfg \
    file://wifi.cfg \
    file://0001-crypto-scatterwalk-Backport-memcpy_sglist.patch \
    file://0002-crypto-algif_aead-use-memcpy_sglist-instead-of-null-skcipher.patch \
    file://0003-crypto-algif_aead-Revert-to-operating-out-of-place-CVE-2026-31431.patch \
    file://0004-crypto-algif_aead-snapshot-IV-for-async-AEAD-requests.patch \
    file://0005-crypto-algif_aead-Fix-minimum-RX-size-check-for-decryption.patch \
    file://cve-2026-46333-ptrace.patch \
    "

# Wi-Fi (wifi.cfg): confirm Kconfig kept the symbols that tegra-image.inc names
# as hard kernel-module-* dependencies. A fragment is a request, not a result --
# a symbol whose parent NVIDIA turns off disappears without a word, and the
# image would then fail one step later with a bare "nothing RPROVIDES".
WENDYOS_WIFI_MODULES = " \
    CONFIG_CFG80211 \
    CONFIG_MAC80211 \
    CONFIG_IWLWIFI \
    CONFIG_IWLMVM \
    CONFIG_RTW88_PCI \
    CONFIG_RTW88_8822BE \
    CONFIG_RTW88_8821CE \
    CONFIG_RTW88_8723DE \
    CONFIG_BT_HCIBTUSB \
    CONFIG_BT_INTEL \
    "

do_configure[postfuncs] += "wendyos_check_wifi_config"
wendyos_check_wifi_config() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "wifi.cfg: no resolved kernel config at $config"
    for symbol in ${WENDYOS_WIFI_MODULES}; do
        grep -q "^$symbol=m$" "$config" || \
            bbfatal "wifi.cfg: $symbol did not resolve to =m for ${MACHINE}"
    done
}
