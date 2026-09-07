# The sysext merge path: the build- and image-side pieces every add-on needs,
# whatever it carries. Required from wendyos.conf when WENDYOS_SYSEXT_ADDONS == "1",
# so nothing here needs its own gate.

# systemd-sysext is off by default in oe-core. Scope to the systemd recipe
# (:pn-systemd): this inc is required at distro scope, so a bare :append would
# land on every recipe's PACKAGECONFIG.
PACKAGECONFIG:append:pn-systemd = " sysext"

# Scope to the product image only (:pn-wendyos-image): this inc is required at
# distro scope, so a bare :append would also hit the Tegra flashing-helper
# images (tegra-espimage, the initramfs images) and pull the merge service into
# the initramfs.
IMAGE_INSTALL:append:pn-wendyos-image = " wendyos-sysext-apply"
