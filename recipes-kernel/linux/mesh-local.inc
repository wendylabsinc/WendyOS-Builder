# Core mesh routing is required independently of Internet sharing.
FILESEXTRAPATHS:prepend := "${THISDIR}/mesh-local:"
SRC_URI += "file://mesh-local.cfg"

python __anonymous() {
    checks = (d.getVarFlag('do_configure', 'postfuncs') or '').split()
    if 'wendyos_check_mesh_local' not in checks:
        d.appendVarFlag('do_configure', 'postfuncs', ' wendyos_check_mesh_local')
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

do_deploy:append() {
    install -m 0644 "${B}/.config" "${DEPLOYDIR}/wendyos-mesh-local-${MACHINE}.config"
}
