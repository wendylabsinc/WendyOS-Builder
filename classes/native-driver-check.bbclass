# Native add-ons omit shared modules only when the matching image guarantees
# their complete installed dependency closure. Check after rootfs depmod.
WENDYOS_NATIVE_DRIVER_CHECKER := "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/check_mesh_kernel_support.py')}"

python __anonymous() {
    if d.getVar('WENDYOS_DRIVER_BASE_MODULES'):
        # Use the same cached kernel outputs as the other image checks.
        for var in ('WENDYOS_KERNEL_CONFIG', 'WENDYOS_KERNEL_RELEASE_FILE', 'WENDYOS_KERNEL_OUTPUTS_DEPENDS'):
            if not d.getVar(var):
                bb.fatal('%s is unset: the distro must require conf/distro/include/mesh-local.inc' % var)
        d.appendVarFlag('do_rootfs', 'depends', ' ' + d.getVar('WENDYOS_KERNEL_OUTPUTS_DEPENDS'))
        d.appendVarFlag('do_rootfs', 'postfuncs', ' wendyos_check_native_driver_base')
        d.appendVarFlag('do_rootfs', 'file-checksums', ' %s:True' % d.getVar('WENDYOS_NATIVE_DRIVER_CHECKER'))
}

python wendyos_check_native_driver_base() {
    import pathlib
    import subprocess
    import sys

    try:
        release = pathlib.Path(d.getVar('WENDYOS_KERNEL_RELEASE_FILE')).read_text().strip()
    except OSError as error:
        bb.fatal('Native driver: cannot read kernel release: %s' % error)
    args = [sys.executable, d.getVar('WENDYOS_NATIVE_DRIVER_CHECKER'),
            '--config', d.getVar('WENDYOS_KERNEL_CONFIG'), '--rootfs', d.getVar('IMAGE_ROOTFS'),
            '--kernel-release', release]
    for name in d.getVar('WENDYOS_DRIVER_BASE_MODULES').split():
        args.extend(('--external-module', name))
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        bb.fatal('Native driver base-image module acceptance failed:\n%s' % result.stdout)
    bb.note(result.stdout.strip())
}
