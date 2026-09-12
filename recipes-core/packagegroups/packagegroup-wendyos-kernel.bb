
PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

SUMMARY:${PN} = "Kernel package group"
RDEPENDS:${PN} = " \
    "

# The modular half of the game-controller contract, for boards whose BSP resolves those
# symbols to modules. RRECOMMENDS out of necessity, not preference: a BSP that builds one
# of these in emits no module package at all, and an RDEPENDS on a package that does not
# exist fails the build. The weak dependency is what the CI check covers, holding each
# machine's resolved kernel config against the image manifest that shipped beside it.
python __anonymous() {
    if d.getVar('WENDYOS_GAME_CONTROLLER') != '1':
        return
    contract = (d.getVar('WENDYOS_GAME_CONTROLLER_MODULES') or '').split()
    packages = [entry.split(':', 1)[1] for entry in contract if ':' in entry]
    if packages:
        d.appendVar('RRECOMMENDS:%s' % d.getVar('PN'), ' ' + ' '.join(packages))
}
