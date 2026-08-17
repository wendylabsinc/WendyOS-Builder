SUMMARY = "v4l2loopback kernel module (virtual V4L2 capture devices)"
DESCRIPTION = "Builds the out-of-tree v4l2loopback module against \
linux-noble-nvidia-tegra. It is required for IP-camera container parity: \
the WendyAgent device agent creates one pinned-number /dev/video<nr> \
loopback node per camera (via V4L2LOOPBACK_CTL_ADD on the control device) \
and feeds decoded RTSP frames into it, so any container that only knows how \
to open a V4L2 device can consume a network camera transparently."
HOMEPAGE = "https://github.com/v4l2loopback/v4l2loopback"

LICENSE = "GPL-2.0-or-later"
LIC_FILES_CHKSUM = "file://COPYING;md5=b234ee4d69f5fce4486a80fdaf4a4263"

inherit module

# v0.15.4 is the newest upstream release tag (verified against the repo's
# tags on 2026-08-13) and the 0.15.x line is confirmed to build against
# kernel 6.8 (linux-noble-nvidia-tegra) — upstream is actively carrying
# compat fixes well past 6.8 (up to 6.18 as of this release), so nothing
# in that range is left unsupported.
# NOTE for Branch C: v0.15.0 changed the public ioctl numbers and struct
# layout ("change public ioctl numbers!" in upstream's ChangeLog) relative
# to the 0.13.x/0.14.x line — the WendyAgent-side ioctl struct must be
# generated from this exact pinned rev's v4l2loopback.h, not an older one.
SRC_URI = " \
    git://github.com/v4l2loopback/v4l2loopback.git;branch=main;protocol=https \
    file://v4l2loopback.conf \
    file://v4l2loopback-options.conf \
    "
SRCREV = "0f9ee86760b7f2bea174b7e3e7a1d38845da0ab4"

COMPATIBLE_MACHINE = "(tegra)"

# Standard single-file Kbuild module (Kbuild just declares
# obj-m := v4l2loopback.o at the repo root) — no nested build subdir and no
# custom kbuild driver like NVIDIA's. BUT the upstream top-level Makefile
# (which module.bbclass's do_compile actually invokes — its own default
# `all` target, not the Kbuild file directly) resolves the kernel build
# tree via its OWN variable `KERNEL_DIR` (default:
# /lib/modules/`uname -r`/build), not the KERNEL_SRC/KERNEL_PATH that
# module.bbclass's module_do_compile passes by default. Left unset, that
# fallback resolves to the BUILD HOST's own running kernel (e.g. the
# Docker build container's kernel) instead of the cross-built target
# kernel, and do_compile fails with "No such file or directory" on
# /lib/modules/<host-kernel-version>/build. Verified against an actual
# build failure on kernel 6.8 (F3, WDY-2430) — this is not a hypothetical.
EXTRA_OEMAKE += "KERNEL_DIR=${STAGING_KERNEL_DIR}"

# The Makefile's default `all` target (which module.bbclass invokes when
# MAKE_TARGETS is unset) also builds utils/v4l2loopback-ctl, a standalone
# userspace CLI for exercising the control device by hand. WendyOS doesn't
# ship or need it — the agent issues the V4L2LOOPBACK_CTL_* ioctls itself
# (docs/v4l2loopback-support.md) — and it fails to build here anyway:
# module_do_compile deliberately unsets CFLAGS/CPPFLAGS and hands the
# kernel-build CC (no --sysroot) to the whole `all` target, which is
# correct for the kernel module but leaves the plain userspace
# v4l2loopback-ctl.c compile unable to find even <sys/types.h>. Restrict
# the build to just the kernel module, which is also all that
# `install:` below needs.
MAKE_TARGETS = "v4l2loopback.ko"

# module_do_install's default MODULES_INSTALL_TARGET ("modules_install")
# doesn't exist in this Makefile either — its own install target is
# literally named `install` (which itself invokes the kernel's
# `modules_install` via `-C $(KERNEL_DIR)`, honoring the MODLIB= override
# module_do_install passes).
MODULES_INSTALL_TARGET = "install"

# modules-load.d forces the module to load at boot (so the control device
# exists for the agent); modprobe.d pins its options (control-device-only,
# exclusive caps). See the payload files themselves for the full rationale.
do_install:append() {
    install -d ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${UNPACKDIR}/v4l2loopback.conf ${D}${sysconfdir}/modules-load.d/v4l2loopback.conf

    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${UNPACKDIR}/v4l2loopback-options.conf ${D}${sysconfdir}/modprobe.d/v4l2loopback-options.conf
}

# The module class packages the .ko into kernel-module-* packages. The
# modules-load.d/modprobe.d conf files ride in the recipe's own package.
FILES:${PN} += " \
    ${sysconfdir}/modules-load.d/v4l2loopback.conf \
    ${sysconfdir}/modprobe.d/v4l2loopback-options.conf \
    "

RPROVIDES:${PN} += "kernel-module-v4l2loopback"
