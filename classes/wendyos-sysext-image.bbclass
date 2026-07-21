# WendyOS driver/firmware add-on, built as a systemd-sysext image.
#
# A per-driver image recipe inherits this and sets IMAGE_INSTALL to the driver's
# kernel-module package (+ any firmware). The result is a single .raw the agent
# stores on /data and merges onto the immutable /usr at runtime.

inherit sysext-image

# sysext-image's ROOTFS_POSTPROCESS runs setfattr (extension-release strict=false
# xattr); attr-native puts setfattr on the do_rootfs PATH.
DEPENDS += "attr-native"

# One xz-compressed squashfs .raw. xz (not the mksquashfs gzip default) because the
# kernel ships the xz decompressor for sysext but not zlib (see sysext.cfg). A single
# fstype is required: sysext-image derives EXTENSION_NAME from ${IMAGE_FSTYPES}.
# The signed-DDI/dm-verity path (systemd-repart --make-ddi) is blacksail-only and a
# later hardening step; scarthgap uses a plain squashfs.
IMAGE_FSTYPES = "squashfs-xz"

# The RPi machine confs append " wic" to IMAGE_FSTYPES unscoped; :remove is applied
# after :append at finalization, so this strips it and leaves exactly the squashfs
# (otherwise EXTENSION_NAME gains a space and a bogus wic disk build runs).
IMAGE_FSTYPES:remove = "wic"

# Bind the add-on to this exact base OS: systemd merges it only if the add-on's
# extension-release ID/VERSION_ID match the device's /etc/os-release. The base
# sysext-image class already defaults these to ${DISTRO}/${DISTRO_VERSION}, which
# match WendyOS os-release (ID=wendyos, VERSION_ID=${DISTRO_VERSION}) — no override
# needed. NOTE: this gates on OS *version*, not the kernel ABI (a kernel or CVE bump
# keeps the same VERSION_ID), so the agent must also verify uname -r before merging.

# Name the extension-release after a short, stable id (default: the recipe name),
# not the long image filename. systemd-sysext merges an image X.raw only when its
# extension-release is named exactly extension-release.X, and the strict-relax xattr
# is not reliably honored from a squashfs — so the agent places the add-on under
# this name (e.g. <id>.raw) and it matches without depending on the xattr.
WENDYOS_SYSEXT_NAME ?= "${PN}"
EXTENSION_NAME = "${WENDYOS_SYSEXT_NAME}"

# An add-on is not a bootable rootfs: no image features, locales, or recommends —
# keep it to exactly the driver payload.
IMAGE_FEATURES = ""
IMAGE_LINGUAS = ""
NO_RECOMMENDATIONS = "1"
