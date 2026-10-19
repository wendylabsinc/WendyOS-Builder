# A fragment is a request; validate the resolved configuration for every BSP.
FILESEXTRAPATHS:prepend := "${THISDIR}/mesh-internet:"
SRC_URI += "file://mesh-internet.cfg"

python __anonymous() {
    checks = (d.getVarFlag('do_configure', 'postfuncs') or '').split()
    if 'wendyos_check_mesh_internet' not in checks:
        d.appendVarFlag('do_configure', 'postfuncs', ' wendyos_check_mesh_internet')
}

wendyos_check_mesh_internet() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "mesh Internet: missing resolved config at $config"
    [ -n "${WENDYOS_MESH_INTERNET_MODULES}" ] || bbfatal "mesh Internet: empty kernel contract"
    for symbol in ${WENDYOS_MESH_INTERNET_BUILTIN}; do
        grep -q "^$symbol=y$" "$config" || bbfatal "mesh Internet: $symbol must be built in for ${MACHINE}"
    done
    for entry in ${WENDYOS_MESH_INTERNET_MODULES}; do
        symbol="${entry%%:*}"
        grep -Eq "^$symbol=(y|m)$" "$config" || bbfatal "mesh Internet: $symbol missing for ${MACHINE}"
    done
}

# Preserve the effective config with image artifacts for acceptance and diagnosis.
do_deploy:append() {
    install -m 0644 "${B}/.config" "${DEPLOYDIR}/wendyos-mesh-internet-${MACHINE}.config"
}
