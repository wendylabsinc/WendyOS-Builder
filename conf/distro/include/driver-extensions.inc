# Driver add-ons (systemd-sysext). Required from wendyos.conf when
# WENDYOS_DRIVER_EXTENSIONS == "1" on an RPi machine, so nothing here needs
# its own gate.
#
# Pulls in the build- and image-side pieces of the merge path:
#   - systemd's sysext support: what merges an add-on onto /usr.
#   - wendyos-sysext-apply:     the boot-time service that merges the .raw
#                               add-ons found on /data.
#   - wendyos-kernel-devkit:    the out-of-tree build kit, deployed next to
#                               the image and not installed in it.

# systemd-sysext is off by default in oe-core. Scope to the systemd recipe
# (:pn-systemd): this inc is required at distro scope, so a bare :append would
# land on every recipe's PACKAGECONFIG.
PACKAGECONFIG:append:pn-systemd = " sysext"

# Scope to the product image only (:pn-wendyos-image): this inc is required at
# distro scope, so a bare :append would also hit the Tegra flashing-helper
# images (tegra-espimage, the initramfs images) and pull the merge service into
# the initramfs.
IMAGE_INSTALL:append:pn-wendyos-image = " wendyos-sysext-apply"

# Build and deploy the devkit alongside the image; it is not installed in the
# rootfs. :do_deploy is explicit because a bare entry maps to
# do_populate_sysroot, which never reaches the devkit's deploy task and leaves
# DEPLOY_DIR_IMAGE without the tarball.
EXTRA_IMAGEDEPENDS:append:pn-wendyos-image = " wendyos-kernel-devkit:do_deploy"
