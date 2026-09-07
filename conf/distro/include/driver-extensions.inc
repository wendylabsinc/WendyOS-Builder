# Driver add-ons (systemd-sysext), the kernel-module half. Required from
# wendyos.conf when WENDYOS_DRIVER_EXTENSIONS == "1" on an RPi machine, so
# nothing here needs its own gate.
#
# The merge path itself lives in sysext-runtime.inc, which wendyos.conf requires
# separately: a board can ship userspace add-ons without ever building a module.

# Build and deploy the devkit alongside the image; it is not installed in the
# rootfs. :do_deploy is explicit because a bare entry maps to
# do_populate_sysroot, which never reaches the devkit's deploy task and leaves
# DEPLOY_DIR_IMAGE without the tarball.
EXTRA_IMAGEDEPENDS:append:pn-wendyos-image = " wendyos-kernel-devkit:do_deploy"
