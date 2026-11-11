# Enabled only by conf/distro/include/usg-access-notice.inc.
WENDYOS_USG_NOTICE_CHECKER := "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/check_usg_access_notice.py')}"
do_rootfs[file-checksums] += "${WENDYOS_USG_NOTICE_CHECKER}:True"
do_rootfs[postfuncs] += "check_usg_access_notice"

python check_usg_access_notice() {
    import subprocess
    import sys
    if d.getVar('PN') != 'wendyos-image':
        return
    command = [sys.executable, d.getVar('WENDYOS_USG_NOTICE_CHECKER'),
               '--rootfs', d.getVar('IMAGE_ROOTFS'),
               '--sysconfdir', d.getVar('sysconfdir'),
               '--datadir', d.getVar('datadir'),
               '--base-libdir', d.getVar('base_libdir'),
               '--base-bindir', d.getVar('base_bindir')]
    if d.getVar('WENDYOS_SSHD') == '1':
        command.append('--ssh')
    if 'dropbear' in (d.getVar('IMAGE_FEATURES') or ''):
        command.append('--dropbear')
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        bb.fatal('USG notice image acceptance failed:\n%s' % result.stdout)
    bb.note(result.stdout.strip())
}
