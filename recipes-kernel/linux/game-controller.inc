# Native game-controller support: the kernel side. Required from a board's kernel bbappend
# when WENDYOS_GAME_CONTROLLER == "1", so nothing here needs its own gate — and no machine
# override either, since only a board that requires this file gets it.
#
# Board-neutral on purpose: the fragment names no arch and no machine, and the symbols it
# is held to live in the distro contract it shares with the image side.

# Its own directory rather than a generic files/: this path is prepended onto every kernel
# recipe's FILESEXTRAPATHS, where a shared files/ would shadow a board layer's own.
FILESEXTRAPATHS:prepend := "${THISDIR}/game-controller:"

SRC_URI += "file://game-controller.cfg"

# A fragment is a request, not a result — Kconfig drops or downgrades a symbol whose parent
# a vendor kernel turned off — so what gets checked is the config Kconfig actually resolved.
# A postfunc rather than an :append, which would inline this body into do_configure itself.
python __anonymous() {
    d.appendVarFlag('do_configure', 'postfuncs', ' wendyos_check_game_controller')
}

wendyos_check_game_controller() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "game-controller: no resolved kernel config at $config"

    # An empty contract would walk both loops below without checking anything.
    [ -n "${WENDYOS_GAME_CONTROLLER_BUILTIN}${WENDYOS_GAME_CONTROLLER_MODULES}" ] || \
        bbfatal "game-controller: the shared contract is empty; is conf/distro/include/game-controller.inc required?"

    for symbol in ${WENDYOS_GAME_CONTROLLER_BUILTIN}; do
        grep -q "^$symbol=y$" "$config" || \
            bbfatal "game-controller: $symbol must be built in for ${MACHINE}"
    done

    # cut, not a shell parameter expansion: BitBake resolves ${...} in a task body against
    # its own datastore before the shell ever sees it.
    for entry in ${WENDYOS_GAME_CONTROLLER_MODULES}; do
        symbol=$(echo "$entry" | cut -d: -f1)
        grep -Eq "^$symbol=(y|m)$" "$config" || \
            bbfatal "game-controller: $symbol is neither built-in nor modular for ${MACHINE}"
    done
}

# Put the checked config beside the image so CI can pair the two: every symbol the kernel
# resolved to a module must have its package in the image that shipped next to it.
#
# An :append and deliberately not a postfunc, unlike the check above: sstate appends its own
# postfunc to do_deploy, and that is what captures DEPLOYDIR, so anything queued behind it
# writes the file too late to reach deploy/images or the sstate archive.
do_deploy:append() {
    install -m 0644 "${B}/.config" "${DEPLOYDIR}/wendyos-game-controller-${MACHINE}.config"
}
