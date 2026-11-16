# Core mesh routing is required independently of Internet sharing.
FILESEXTRAPATHS:prepend := "${THISDIR}/mesh-local:"
SRC_URI += "file://mesh-local.cfg"

# Bluetooth-capable machines must support the BLE mesh carrier regardless of
# vendor defaults. LAN-only machines do not need Bluetooth kernel support.
SRC_URI += "${@bb.utils.contains('MACHINE_FEATURES', 'bluetooth', 'file://mesh-ble.cfg', '', d)}"

python __anonymous() {
    checks = (d.getVarFlag('do_configure', 'postfuncs') or '').split()
    if 'wendyos_check_mesh_local' not in checks:
        d.appendVarFlag('do_configure', 'postfuncs', ' wendyos_check_mesh_local')
    if bb.utils.contains('MACHINE_FEATURES', 'bluetooth', True, False, d):
        if 'wendyos_check_mesh_ble' not in checks:
            d.appendVarFlag('do_configure', 'postfuncs', ' wendyos_check_mesh_ble')
}

wendyos_check_mesh_local() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "local mesh: missing resolved kernel config at $config"
    for list in "${WENDYOS_MESH_LOCAL_BUILTIN}" "${WENDYOS_MESH_LOCAL_MODULES}"; do
        set -- $list
        [ $# -gt 0 ] || bbfatal "local mesh: empty kernel contract"
    done
    for symbol in ${WENDYOS_MESH_LOCAL_BUILTIN}; do
        grep -q "^$symbol=y$" "$config" || \
            bbfatal "local mesh: $symbol must be built in for ${MACHINE}"
    done
    for entry in ${WENDYOS_MESH_LOCAL_MODULES}; do
        symbol="${entry%%:*}"
        grep -Eq "^$symbol=(y|m)$" "$config" || \
            bbfatal "local mesh: $symbol missing for ${MACHINE}"
    done
}

wendyos_check_mesh_ble() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "mesh BLE: missing resolved kernel config at $config"
    grep -Eq '^CONFIG_BT=(y|m)$' "$config" || \
        bbfatal "mesh BLE: CONFIG_BT missing for ${MACHINE}"
    grep -q '^CONFIG_BT_LE=y$' "$config" || \
        bbfatal "mesh BLE: CONFIG_BT_LE must be enabled for ${MACHINE}"
}

do_deploy:append() {
    install -m 0644 "${B}/.config" "${DEPLOYDIR}/wendyos-mesh-local-${MACHINE}.config"
}
