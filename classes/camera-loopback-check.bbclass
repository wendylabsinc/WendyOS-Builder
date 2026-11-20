# Check installed files and their transitive module dependencies after depmod.
WENDYOS_CAMERA_LOOPBACK_CHECKER := "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/check_mesh_kernel_support.py')}"
do_rootfs[depends] += "${WENDYOS_KERNEL_OUTPUTS_DEPENDS}"
do_rootfs[file-checksums] += "${WENDYOS_CAMERA_LOOPBACK_CHECKER}:True"
do_rootfs[postfuncs] += "wendyos_check_camera_loopback_rootfs"

python () {
    for var in ('WENDYOS_KERNEL_CONFIG', 'WENDYOS_KERNEL_RELEASE_FILE', 'WENDYOS_KERNEL_OUTPUTS_DEPENDS'):
        if not d.getVar(var):
            bb.fatal('%s is unset: the distro must require conf/distro/include/mesh-local.inc' % var)
}

python wendyos_check_camera_loopback_rootfs() {
    import pathlib
    import subprocess
    import sys

    try:
        release = pathlib.Path(d.getVar('WENDYOS_KERNEL_RELEASE_FILE')).read_text().strip()
    except OSError as error:
        bb.fatal('Camera loopback: cannot read kernel release: %s' % error)
    args = [sys.executable, d.getVar('WENDYOS_CAMERA_LOOPBACK_CHECKER'),
            '--config', d.getVar('WENDYOS_KERNEL_CONFIG'), '--rootfs', d.getVar('IMAGE_ROOTFS'),
            '--kernel-release', release,
            '--module', 'CONFIG_VIDEO_DEV:videodev',
            '--module', 'CONFIG_VIDEOBUF2_VMALLOC:videobuf2_vmalloc',
            '--external-module', 'v4l2loopback']
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        bb.fatal('Camera loopback image acceptance failed:\n%s' % result.stdout)
    bb.note(result.stdout.strip())
}
