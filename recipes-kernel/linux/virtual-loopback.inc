# Camera and audio loopback prerequisites for the linux-yocto VM and QEMU images.
FILESEXTRAPATHS:prepend := "${THISDIR}/virtual-loopback:"
SRC_URI += "file://virtual-loopback.cfg"

python __anonymous() {
    checks = (d.getVarFlag('do_configure', 'postfuncs') or '').split()
    if 'wendyos_check_virtual_loopback' not in checks:
        d.appendVarFlag('do_configure', 'postfuncs', ' wendyos_check_virtual_loopback')
}

wendyos_check_virtual_loopback() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "virtual loopback: missing resolved kernel config at $config"
    for symbol in CONFIG_VIDEO_DEV CONFIG_VIDEOBUF2_VMALLOC; do
        grep -Eq "^$symbol=(y|m)$" "$config" || \
            bbfatal "virtual loopback: $symbol is disabled for ${MACHINE}"
    done
    # The image requires a module package and the agent loads ALSA on demand.
    grep -q '^CONFIG_SND_ALOOP=m$' "$config" || \
        bbfatal "virtual loopback: CONFIG_SND_ALOOP must be modular for ${MACHINE}"
}
