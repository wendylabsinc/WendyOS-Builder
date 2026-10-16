# Run after do_rootfs, not ROOTFS_POSTPROCESS_COMMAND: oe.rootfs generates
# modules.dep after that command. Validate the actual image before any format
# (including OTA) can be produced, for local builds as well as CI.
WENDYOS_MESH_KERNEL_CHECKER := "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/check_mesh_kernel_support.py')}"
do_rootfs[depends] += "virtual/kernel:do_shared_workdir"
do_rootfs[file-checksums] += "${WENDYOS_MESH_KERNEL_CHECKER}:True"
do_rootfs[postfuncs] += "wendyos_check_mesh_rootfs"

python wendyos_check_mesh_rootfs() {
    import pathlib
    import subprocess
    import sys

    checker = d.getVar('WENDYOS_MESH_KERNEL_CHECKER')
    build = pathlib.Path(d.getVar('STAGING_KERNEL_BUILDDIR'))
    try:
        release = (build / 'include/config/kernel.release').read_text().strip()
    except OSError as error:
        bb.fatal('mesh kernel: cannot read compiled kernel release: %s' % error)
    args = [sys.executable, checker, '--config', str(build / '.config'),
            '--rootfs', d.getVar('IMAGE_ROOTFS'), '--kernel-release', release]
    for scope in ('LOCAL', 'INTERNET'):
        for symbol in (d.getVar('WENDYOS_MESH_%s_BUILTIN' % scope) or '').split():
            args.extend(('--builtin', symbol))
        for entry in (d.getVar('WENDYOS_MESH_%s_MODULES' % scope) or '').split():
            args.extend(('--module', entry))
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        bb.fatal('mesh kernel image acceptance failed:\n%s' % result.stdout)
    bb.note(result.stdout.strip())
}
# The scope loop above constructs variable names; make the task signature's
# dependency on both contracts explicit for BitBake's variable scanner.
wendyos_check_mesh_rootfs[vardeps] += "WENDYOS_MESH_LOCAL_BUILTIN WENDYOS_MESH_LOCAL_MODULES WENDYOS_MESH_INTERNET_BUILTIN WENDYOS_MESH_INTERNET_MODULES"
