# Shared WendyOS Bluetooth-transport kernel contract.
#
# Unlike the game-controller contract, this one is opt-in per machine: it
# exists to pin a board to the mainline Bluetooth stack (btusb and friends)
# where a BSP would otherwise ship a vendor driver for the same radio. A
# vendor and a mainline driver both claiming one USB ID is a probe race, so
# a board must only enable this once its vendor driver is actually removed.
#
# First adopter: Jetson Orin Nano (RTL8822CE on USB 0bda:c822), whose NVIDIA
# out-of-tree rtk_btusb driver drops BLE HID links in a ~2 s connect/drop
# loop. The mainline btusb+btrtl pair replaces it.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
WENDYOS_BLUETOOTH_ENABLE ?= "0"
SRC_URI:append = "${@' file://bluetooth.cfg' if d.getVar('WENDYOS_BLUETOOTH_ENABLE') == '1' else ''}"

WENDYOS_BLUETOOTH_SYMBOLS = " \
    CONFIG_BT \
    CONFIG_BT_RFCOMM \
    CONFIG_BT_HIDP \
    ${WENDYOS_BLUETOOTH_EXTRA_SYMBOLS} \
    "
# Transport symbols the adopting BSP appends (e.g. CONFIG_BT_HCIBTUSB).
WENDYOS_BLUETOOTH_EXTRA_SYMBOLS ?= ""

# Symbols that must NOT resolve =y or =m — an in-tree vendor driver that
# would race the mainline stack for the same hardware. Package-level vendor
# drivers are excluded by the image validator instead (they never appear in
# the kernel config).
WENDYOS_BLUETOOTH_FORBIDDEN_SYMBOLS ?= ""

# Validate the effective config after Kconfig has resolved all BSP
# dependencies, same rationale as wendy-game-controller.inc: a fragment is a
# request, not a guarantee.
do_configure:append() {
    [ "${WENDYOS_BLUETOOTH_ENABLE}" = "1" ] || return 0
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "bluetooth: effective kernel config not found at $config"

    for symbol in ${WENDYOS_BLUETOOTH_SYMBOLS}; do
        if ! grep -Eq "^${symbol}=(y|m)$" "$config"; then
            bbfatal "bluetooth: ${symbol} is neither built-in nor modular in $config"
        fi
    done
    for symbol in ${WENDYOS_BLUETOOTH_FORBIDDEN_SYMBOLS}; do
        if grep -Eq "^${symbol}=(y|m)$" "$config"; then
            bbfatal "bluetooth: vendor driver symbol ${symbol} is still enabled in $config"
        fi
    done
}

# Publish the exact config checked above beside the image artifacts; CI
# cross-checks it against the image manifest (=m needs its kernel-module
# package present, vendor packages must be absent).
do_deploy:append() {
    [ "${WENDYOS_BLUETOOTH_ENABLE}" = "1" ] || return 0
    install -m 0644 "${B}/.config" "${DEPLOYDIR}/wendyos-bluetooth-${MACHINE}.config"
}
