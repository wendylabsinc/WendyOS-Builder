# modules.dep is generated after ROOTFS_POSTPROCESS_COMMAND. Run after do_rootfs
# so every local and CI image must include the matching modules and dependencies.
WENDYOS_SENSOR_LOOPBACK_CHECKER := "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/check_sensor_loopback_support.py')}"
WENDYOS_SENSOR_LOOPBACK_KERNEL_CHECKER := "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/check_mesh_kernel_support.py')}"
do_rootfs[depends] += "virtual/kernel:do_shared_workdir"
do_rootfs[file-checksums] += "${WENDYOS_SENSOR_LOOPBACK_CHECKER}:True ${WENDYOS_SENSOR_LOOPBACK_KERNEL_CHECKER}:True"
do_rootfs[postfuncs] += "wendyos_check_sensor_loopback_rootfs"

python wendyos_check_sensor_loopback_rootfs() {
    import pathlib
    import subprocess
    import sys

    build = pathlib.Path(d.getVar('STAGING_KERNEL_BUILDDIR'))
    try:
        release = (build / 'include/config/kernel.release').read_text().strip()
    except OSError as error:
        bb.fatal('SensorLink loopback: cannot read compiled kernel release: %s' % error)
    args = [sys.executable, d.getVar('WENDYOS_SENSOR_LOOPBACK_CHECKER'),
            '--config', str(build / '.config'), '--rootfs', d.getVar('IMAGE_ROOTFS'),
            '--kernel-release', release]
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        bb.fatal('SensorLink loopback image acceptance failed:\n%s' % result.stdout)
    bb.note(result.stdout.strip())
}
