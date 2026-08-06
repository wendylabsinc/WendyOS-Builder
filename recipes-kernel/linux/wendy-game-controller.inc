# Shared WendyOS game-controller kernel contract.
#
# Included by every shipping kernel recipe (Jetson JP6/JP7, Raspberry Pi, and
# x86). Keep the symbols and validation in one place so BSP defconfig changes
# cannot silently remove evdev or a controller transport on only one platform.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
WENDYOS_GAME_CONTROLLER_ENABLE ?= "1"
SRC_URI:append = "${@' file://game-controller.cfg' if d.getVar('WENDYOS_GAME_CONTROLLER_ENABLE') == '1' else ''}"

WENDYOS_GAME_CONTROLLER_SYMBOLS = " \
    CONFIG_INPUT_EVDEV \
    CONFIG_INPUT_JOYDEV \
    CONFIG_HID \
    CONFIG_HID_GENERIC \
    CONFIG_USB_HID \
    CONFIG_UHID \
    CONFIG_BT_HIDP \
    CONFIG_JOYSTICK_XPAD \
    CONFIG_HID_MICROSOFT \
    "

# Validate the effective config after Kconfig has resolved all BSP
# dependencies. A fragment alone is not a guarantee: Kconfig can downgrade or
# discard a requested symbol when a vendor kernel changes one of its parents.
do_configure:append() {
    [ "${WENDYOS_GAME_CONTROLLER_ENABLE}" = "1" ] || return 0
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "game-controller: effective kernel config not found at $config"

    for symbol in ${WENDYOS_GAME_CONTROLLER_SYMBOLS}; do
        if ! grep -Eq "^${symbol}=(y|m)$" "$config"; then
            bbfatal "game-controller: ${symbol} is neither built-in nor modular in $config"
        fi
    done
}

# Put the exact config checked above beside the image artifacts. CI combines
# it with wendyos-image's package manifest: every =m driver must have its
# kernel-module package in the finished image, while =y needs no package.
do_deploy:append() {
    [ "${WENDYOS_GAME_CONTROLLER_ENABLE}" = "1" ] || return 0
    install -m 0644 "${B}/.config" "${DEPLOYDIR}/wendyos-game-controller-${MACHINE}.config"
}
