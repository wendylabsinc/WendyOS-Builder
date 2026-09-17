# Native game-controller support: the kernel side. Required from a board's kernel bbappend
# when WENDYOS_GAME_CONTROLLER == "1", so nothing here needs its own gate.

# Its own directory, not a generic files/: this is prepended onto every kernel recipe's
# FILESEXTRAPATHS, where a shared files/ would shadow a board layer's own.
FILESEXTRAPATHS:prepend := "${THISDIR}/game-controller:"

SRC_URI += "file://game-controller.cfg"

# A fragment is a request, not a result: Kconfig drops a symbol whose parent a vendor
# kernel turned off, so the check reads what Kconfig actually resolved.
python __anonymous() {
    d.appendVarFlag('do_configure', 'postfuncs', ' wendyos_check_game_controller')
}

wendyos_check_game_controller() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "game-controller: no resolved kernel config at $config"

    # An empty list would walk its loop below without checking anything.
    for list in "${WENDYOS_GAME_CONTROLLER_BUILTIN}" "${WENDYOS_GAME_CONTROLLER_MODULES}"; do
        set -- $list
        [ $# -gt 0 ] || bbfatal "game-controller: half the shared contract is empty"
    done

    for symbol in ${WENDYOS_GAME_CONTROLLER_BUILTIN}; do
        grep -q "^$symbol=y$" "$config" || \
            bbfatal "game-controller: $symbol must be built in for ${MACHINE}"
    done

    for entry in ${WENDYOS_GAME_CONTROLLER_MODULES}; do
        symbol="${entry%%:*}"
        grep -Eq "^$symbol=(y|m)$" "$config" || \
            bbfatal "game-controller: $symbol is neither built-in nor modular for ${MACHINE}"
    done
}

# Deployed so CI can pair it with the image manifest. An :append and not a postfunc:
# sstate's own do_deploy postfunc captures DEPLOYDIR, so anything queued behind it lands
# too late to reach deploy/images.
do_deploy:append() {
    install -m 0644 "${B}/.config" "${DEPLOYDIR}/wendyos-game-controller-${MACHINE}.config"
}
