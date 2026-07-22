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

# Bake the add-on's module list into the image so it is self-describing: the driver
# declares its own modules here, and no --module (or manifest modules_load) is needed
# at install time. wendyos-sysext-apply reads /usr/lib/modules-load.d/<name>.conf from
# the merged add-on (a /data override still wins for bench/dev). Space-separated;
# depmod resolves deps, so a top module pulls in what it needs (e.g. "apex" -> gasket).
WENDYOS_SYSEXT_MODULES ?= ""

wendyos_sysext_write_modules_load() {
    if [ -n "${WENDYOS_SYSEXT_MODULES}" ]; then
        install -d ${IMAGE_ROOTFS}/usr/lib/modules-load.d
        conf=${IMAGE_ROOTFS}/usr/lib/modules-load.d/${WENDYOS_SYSEXT_NAME}.conf
        : > $conf
        for m in ${WENDYOS_SYSEXT_MODULES}; do
            echo "$m" >> $conf
        done
    fi
}
ROOTFS_POSTPROCESS_COMMAND += "wendyos_sysext_write_modules_load;"

# Strip the image down to exactly the driver payload before it is packed.
# `inherit sysext-image` builds a full rootfs and the module package hard-RDEPENDS
# the whole kernel package, so the tree otherwise carries base-files, bash, glibc,
# ld-linux, libtinfo and the kernel's module metadata. systemd-sysext merges the
# extension's ENTIRE /usr onto the host, so those files would SHADOW the host's own
# copies — a stale glibc/bash could silently un-patch the host after a same-VERSION_ID
# security update — and bloat every driver .raw many-fold. Keep only: the out-of-tree
# .ko(s) (modules/<kver>/updates), the baked module-load + modprobe config, firmware,
# and the extension-release marker. Runs in IMAGE_PREPROCESS_COMMAND so it is after
# every do_rootfs step (extension-release, modules-load, depmod) and just before the
# squashfs is built. Host build tooling, so GNU coreutils are fine here.
# Delete in place rather than stage-and-copy: under do_image's pseudo context a
# cp -a to a dir outside the rootfs cannot preserve ownership (EINVAL). Keep only
# /usr/lib/{extension-release.d,modules-load.d,modprobe.d,firmware} and
# /usr/lib/modules/<kver>/updates (the out-of-tree .ko); drop everything else,
# including the stock module tree + the incomplete modules.dep (the on-device
# apply runs depmod after merge). The host's own /lib->/usr/lib resolves the .ko,
# so the extension needs no base symlinks.
wendyos_sysext_strip_to_payload() {
    root="${IMAGE_ROOTFS}"

    find "$root" -mindepth 1 -maxdepth 1 ! -name usr -exec rm -rf {} +
    if [ -d "$root/usr" ]; then
        find "$root/usr" -mindepth 1 -maxdepth 1 ! -name lib -exec rm -rf {} +
    fi
    if [ -d "$root/usr/lib" ]; then
        find "$root/usr/lib" -mindepth 1 -maxdepth 1 \
            ! -name extension-release.d ! -name modules-load.d \
            ! -name modprobe.d ! -name firmware ! -name modules \
            -exec rm -rf {} +
    fi
    if [ -d "$root/usr/lib/modules" ]; then
        for kv in "$root/usr/lib/modules"/*; do
            [ -d "$kv" ] || continue
            find "$kv" -mindepth 1 -maxdepth 1 ! -name updates -exec rm -rf {} +
            [ -d "$kv/updates" ] || rm -rf "$kv"
        done
        rmdir "$root/usr/lib/modules" 2>/dev/null || true
    fi

    if [ ! -e "$root/usr/lib/extension-release.d" ]; then
        bbfatal "wendyos-sysext: extension-release.d missing after strip; refusing to build an unmergeable add-on"
    fi
}
IMAGE_PREPROCESS_COMMAND += "wendyos_sysext_strip_to_payload;"
