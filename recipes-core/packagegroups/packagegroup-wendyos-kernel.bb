
PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

SUMMARY:${PN} = "Kernel package group"
RDEPENDS:${PN} = " \
    "

# Modular core mesh features are optional packages only because BSPs may build
# them in. The image acceptance gate verifies installed module closure for =m.
python __anonymous() {
    entries = (d.getVar('WENDYOS_MESH_LOCAL_MODULES') or '').split()
    packages = ' '.join('kernel-module-' + e.split(':', 1)[1].replace('_', '-').lower()
                        for e in entries if ':' in e)
    d.appendVar('RRECOMMENDS:%s' % d.getVar('PN'), ' ' + packages)
}

# The modular half of the game-controller contract. RRECOMMENDS by necessity: a symbol the
# BSP builds in emits no package at all, so an RDEPENDS would fail the build. The CI check
# is what closes the weak link.
python __anonymous() {
    if d.getVar('WENDYOS_GAME_CONTROLLER') != '1':
        return
    entries = (d.getVar('WENDYOS_GAME_CONTROLLER_MODULES') or '').split()
    packages = ' '.join(e.split(':', 1)[1] for e in entries if ':' in e)
    d.appendVar('RRECOMMENDS:%s' % d.getVar('PN'), ' ' + packages)
}
