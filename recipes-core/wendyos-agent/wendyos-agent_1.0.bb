SUMMARY = "WendyOS Agent"
DESCRIPTION = "WendyOS agent binary for device management"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# The wendyos-agent binary is published per-release in wendylabsinc/WendyOS.
#
# CI resolves the latest *stable* release (tag + asset sha256) and passes them
# in via WENDYOS_AGENT_VERSION / WENDYOS_AGENT_SHA256 (whitelisted through
# BB_ENV_PASSTHROUGH_ADDITIONS in the Makefile). Pinning both the version and
# the checksum makes the fetch reproducible AND lets sstate notice a new
# release: the version is embedded in SRC_URI and the checksum, so both become
# part of the do_fetch task signature. A new release therefore changes the
# signature and re-runs the fetch instead of serving a stale cached binary --
# which is exactly the bug this recipe used to have when it downloaded the
# binary inside do_compile (invisible to BitBake's hashing).
#
# The ??= defaults are the fallback for local builds with no env override:
# they pin a known-good version so local builds stay reproducible. Bump them
# when you want local builds to track a newer agent; CI always overrides them
# with the latest stable release.
WENDYOS_AGENT_VERSION ??= "2026.07.03-194041"

# The release publishes one tarball per arch (see WENDYOS_AGENT_RELEASE_ARCH
# below), each with its own checksum. WENDYOS_AGENT_SHA256 defaults to the hash
# matching the arch THIS build fetches, picked from the per-arch defaults. CI
# still passes WENDYOS_AGENT_SHA256 directly via the environment for whichever
# arch it builds; because this default is weak (??=), that env value wins. Bump
# these together with WENDYOS_AGENT_VERSION.
WENDYOS_AGENT_SHA256_arm64 ??= "c84d35aee93a25866b9da41a112463f887f6cbb4cebcf2093c9795e8f3fafaa9"
WENDYOS_AGENT_SHA256_amd64 ??= "33e3ac7ad8bdb3e715d1465e74a0fcd58bf548d12faa799d17e9f65b3317f9e3"
WENDYOS_AGENT_SHA256  ??= "${@d.getVar('WENDYOS_AGENT_SHA256_' + (d.getVar('WENDYOS_AGENT_RELEASE_ARCH') or 'arm64'))}"

# Surface the resolved agent version as the package version for traceability
# (e.g. in the image manifest). Hyphens are not valid in PV, so map them to
# dots: 2026.06.10-142200 -> 2026.06.10.142200.
PV = "${@d.getVar('WENDYOS_AGENT_VERSION').replace('-', '.')}"

# Release asset architecture. The upstream release publishes one tarball per
# arch (wendy-agent-linux-<arch>-<version>.tar.gz). Default to arm64 for
# Tegra/RPi; the x86 machines override this to amd64. CI passes the matching
# WENDYOS_AGENT_SHA256 for whichever tarball this build fetches.
WENDYOS_AGENT_RELEASE_ARCH = "arm64"
WENDYOS_AGENT_RELEASE_ARCH:x86-wendyos = "amd64"

SRC_URI = "https://github.com/wendylabsinc/WendyOS/releases/download/${WENDYOS_AGENT_VERSION}/wendy-agent-linux-${WENDYOS_AGENT_RELEASE_ARCH}-${WENDYOS_AGENT_VERSION}.tar.gz;name=agent \
           file://wendyos-agent.service \
           file://wendyos-agent-updater.service \
           file://wendyos-agent-updater.timer \
           file://wendyos-agent-updater.sh \
           file://download-wendyos-agent.sh"
SRC_URI[agent.sha256sum] = "${WENDYOS_AGENT_SHA256}"

S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "wendyos-agent.service wendyos-agent-updater.service wendyos-agent-updater.timer"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Install the pre-built binary (fetched + checksum-verified by do_fetch)
    # into /usr/local/bin so it lives alongside runtime updates written by
    # wendyos-agent-updater.sh. The tarball unpacks to
    # wendy-agent-linux-<arch>/wendy-agent; find it rather than hard-coding the
    # inner directory so a future asset layout change fails loudly here instead
    # of silently shipping nothing.
    BINARY=$(find ${S} -type f -name wendy-agent ! -path "*/wendy-cli*" | head -1)
    if [ -z "${BINARY}" ]; then
        bbfatal "wendy-agent binary not found in unpacked release archive"
    fi

    install -d ${D}/usr/local/bin
    install -m 0755 "${BINARY}" ${D}/usr/local/bin/wendy-agent

    # Install systemd services
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-agent.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/wendyos-agent-updater.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/wendyos-agent-updater.timer ${D}${systemd_system_unitdir}/

    # Install updater and download scripts
    install -d ${D}/opt/wendyos/bin
    install -m 0755 ${UNPACKDIR}/wendyos-agent-updater.sh ${D}/opt/wendyos/bin/
    install -m 0755 ${UNPACKDIR}/download-wendyos-agent.sh ${D}/opt/wendyos/bin/

    # Create runtime directories
    install -d ${D}/var/lib/wendyos-agent
    install -d ${D}/var/lib/wendy-agent
    install -d ${D}/opt/wendy
}

FILES:${PN} = "/usr/local/bin/wendy-agent \
               /opt/wendyos/bin/* \
               /opt/wendy \
               ${systemd_system_unitdir}/* \
               /var/lib/wendyos-agent \
               /var/lib/wendy-agent"

# Skip QA checks for the pre-built, vendored binary:
#   already-stripped - upstream ships a stripped release binary.
#   buildpaths       - the agent is a Go binary built in WendyOS's own CI
#                      (also GitHub Actions), so it embeds /home/runner/...
#                      build paths that we cannot trim out of a binary we did
#                      not compile. blacksail promotes buildpaths to a fatal
#                      ERROR_QA, which is why this only surfaces on the cold
#                      blacksail Jetson builds. The embedded path is inert
#                      debug metadata on-device. Proper fix is upstream
#                      building the agent with `go build -trimpath`; drop this
#                      skip once releases ship trimmed binaries.
INSANE_SKIP:${PN} += "already-stripped buildpaths"

# Runtime dependencies
# curl/wget needed for auto-updater, tar for extraction
RDEPENDS:${PN} = "bash curl tar"
