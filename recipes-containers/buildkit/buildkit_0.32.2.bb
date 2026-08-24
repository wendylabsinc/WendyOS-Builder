SUMMARY = "BuildKit daemon, for devices acting as a wendy build host"
DESCRIPTION = "buildkitd + buildctl, so `wendy run --build-host <device>` can \
build container images on this device instead of a developer's laptop."
HOMEPAGE = "https://github.com/moby/buildkit"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

# Upstream's own release binaries, pinned by version AND checksum for the same
# reason wendyos-agent pins both: the version is part of SRC_URI and the checksum
# is part of the do_fetch signature, so a bump re-runs the fetch instead of
# serving a stale cached tarball.
#
# 0.32.2 is the version verified end to end on a Jetson AGX Thor and a DGX Spark
# acting as build hosts. Bump version and BOTH checksums together.
BUILDKIT_VERSION = "0.32.2"
BUILDKIT_RELEASE_ARCH = "arm64"
BUILDKIT_RELEASE_ARCH:x86-wendyos = "amd64"

SRC_URI = "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.linux-${BUILDKIT_RELEASE_ARCH}.tar.gz;name=buildkit \
           file://buildkit.service \
           file://buildkitd.toml"

SRC_URI[buildkit.sha256sum] = "${@d.getVar('BUILDKIT_SHA256_' + d.getVar('BUILDKIT_RELEASE_ARCH'))}"
BUILDKIT_SHA256_arm64 = "9e8f46bf309ec0ab262967be5538a4dbe06be756a82621f98253933bac5dcf92"
BUILDKIT_SHA256_amd64 = "2975d0f651ad96ba8b80b9992ae1f9a964f4408569af5b6dc36544165c3926af"

S = "${UNPACKDIR}"

inherit systemd

# NOT auto-enabled. Running other people's builds is something a device opts
# into: the agent gates it on its own marker file (build-host-enabled, set by
# `wendy cloud device build-host enable`), and starting the daemon on every
# device would spend memory on hosts that will never build. The unit is
# installed and left disabled; enabling the role starts it.
SYSTEMD_SERVICE:${PN} = "buildkit.service"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

COMPATIBLE_MACHINE = "^(?!qemuall).*$"

do_install() {
    # /opt, not /usr/local: a merged sysext driver add-on turns /usr into an
    # ephemeral overlay, so anything installed under it is discarded on the next
    # reboot (same reason wendyos-agent lives in /opt/wendyos/bin).
    install -d ${D}/opt/buildkit/bin

    # The tarball unpacks to bin/. Install every shipped binary rather than a
    # hand-listed subset: buildkitd needs its runc and CNI helpers, and the
    # buildkit-qemu-* binaries are what a future emulated-platform build would
    # use. Find them rather than globbing a hard-coded path so an upstream
    # layout change fails loudly here instead of silently shipping nothing.
    BINDIR=$(find ${S} -type d -name bin | head -1)
    if [ -z "${BINDIR}" ]; then
        bbfatal "no bin/ directory in the unpacked buildkit release archive"
    fi
    for f in "${BINDIR}"/*; do
        install -m 0755 "$f" ${D}/opt/buildkit/bin/
    done
    test -x ${D}/opt/buildkit/bin/buildkitd || bbfatal "buildkitd missing from the release archive"
    test -x ${D}/opt/buildkit/bin/buildctl  || bbfatal "buildctl missing from the release archive"

    # The agent execs a bare "buildctl" (build_service.go), so it must be on
    # PATH. Symlinks only -- the binaries themselves stay in /opt.
    install -d ${D}${bindir}
    ln -sf /opt/buildkit/bin/buildctl  ${D}${bindir}/buildctl
    ln -sf /opt/buildkit/bin/buildkitd ${D}${bindir}/buildkitd

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/buildkit.service ${D}${systemd_system_unitdir}/

    # Config, which is where the state directory is set. See buildkitd.toml.
    install -d ${D}${sysconfdir}/buildkit
    install -m 0644 ${UNPACKDIR}/buildkitd.toml ${D}${sysconfdir}/buildkit/
}

FILES:${PN} = "/opt/buildkit/bin/* \
               ${bindir}/buildctl \
               ${bindir}/buildkitd \
               ${sysconfdir}/buildkit/buildkitd.toml \
               ${systemd_system_unitdir}/* \
               "

# Prebuilt upstream binaries: no source to strip or split, and they are already
# built for the target arch.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"
EXCLUDE_FROM_SHLIBS = "1"
SKIP_FILEDEPS:${PN} = "1"

RDEPENDS:${PN} += "ca-certificates"
