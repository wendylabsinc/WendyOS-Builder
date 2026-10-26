# Native add-ons omit shared modules only when the matching image guarantees
# their complete installed dependency closure. Check after rootfs depmod.
WENDYOS_NATIVE_DRIVER_CHECKER := "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/check_mesh_kernel_support.py')}"

python __anonymous() {
    if d.getVar('WENDYOS_DRIVER_BASE_MODULES'):
        d.appendVarFlag('do_rootfs', 'depends', ' virtual/kernel:do_shared_workdir')
        d.appendVarFlag('do_rootfs', 'postfuncs', ' wendyos_check_native_driver_base')
        d.appendVarFlag('do_rootfs', 'file-checksums', ' %s:True' % d.getVar('WENDYOS_NATIVE_DRIVER_CHECKER'))
}

python wendyos_check_native_driver_base() {
    import pathlib
    import subprocess
    import sys

    build = pathlib.Path(d.getVar('STAGING_KERNEL_BUILDDIR'))
    try:
        release = (build / 'include/config/kernel.release').read_text().strip()
    except OSError as error:
        bb.fatal('Native driver: cannot read compiled kernel release: %s' % error)
    args = [sys.executable, d.getVar('WENDYOS_NATIVE_DRIVER_CHECKER'),
            '--config', str(build / '.config'), '--rootfs', d.getVar('IMAGE_ROOTFS'),
            '--kernel-release', release]
    for name in d.getVar('WENDYOS_DRIVER_BASE_MODULES').split():
        args.extend(('--external-module', name))
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        bb.fatal('Native driver base-image module acceptance failed:\n%s' % result.stdout)
    bb.note(result.stdout.strip())
}
