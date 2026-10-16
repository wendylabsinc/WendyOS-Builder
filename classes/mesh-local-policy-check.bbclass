# Core mesh policy is required even when Internet sharing is disabled.
WENDYOS_MESH_POLICY_CHECKER := "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/check_mesh_local_policy.py')}"
do_rootfs[file-checksums] += "${WENDYOS_MESH_POLICY_CHECKER}:True"
do_rootfs[postfuncs] += "wendyos_check_mesh_local_policy"

python wendyos_check_mesh_local_policy() {
    import subprocess
    import sys
    result = subprocess.run([sys.executable, d.getVar('WENDYOS_MESH_POLICY_CHECKER'),
                             '--rootfs', d.getVar('IMAGE_ROOTFS')],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        bb.fatal('core mesh policy image acceptance failed:\n%s' % result.stdout)
    bb.note(result.stdout.strip())
}
