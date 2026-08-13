SUMMARY = "v4l2loopback kernel module (virtual V4L2 capture devices)"
DESCRIPTION = "Builds the out-of-tree v4l2loopback module against \
linux-noble-nvidia-tegra. It is required for IP-camera container parity: \
the WendyAgent device agent creates one pinned-number /dev/video<nr> \
loopback node per camera (via V4L2LOOPBACK_CTL_ADD on the control device) \
and feeds decoded RTSP frames into it, so any container that only knows how \
to open a V4L2 device can consume a network camera transparently."
HOMEPAGE = "https://github.com/v4l2loopback/v4l2loopback"

LICENSE = "GPL-2.0-only"
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
# custom kbuild driver like NVIDIA's, so plain `inherit module` is enough;
# no EXTRA_OEMAKE/KERNEL_SRC overrides are needed.

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
