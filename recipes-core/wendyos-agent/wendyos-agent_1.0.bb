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
WENDYOS_AGENT_VERSION ??= "2026.06.17-194156"
WENDYOS_AGENT_SHA256  ??= "72b08b61bb26ab4ce9693e19fe5f44d7108f7ddbea587470249821302c3f24b9"

# Surface the resolved agent version as the package version for traceability
# (e.g. in the image manifest). Hyphens are not valid in PV, so map them to
# dots: 2026.06.10-142200 -> 2026.06.10.142200.
PV = "${@d.getVar('WENDYOS_AGENT_VERSION').replace('-', '.')}"

SRC_URI = "https://github.com/wendylabsinc/WendyOS/releases/download/${WENDYOS_AGENT_VERSION}/wendy-agent-linux-arm64-${WENDYOS_AGENT_VERSION}.tar.gz;name=agent \
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

do_compile() {
    case "${TARGET_ARCH}" in
        x86_64|x86-64)
            AGENT_RELEASE_ARCH="amd64"
            ;;
        aarch64|arm64)
            AGENT_RELEASE_ARCH="arm64"
            ;;
        *)
            bbfatal "Unsupported TARGET_ARCH for wendy-agent: ${TARGET_ARCH}"
            ;;
    esac

    bbnote "Downloading wendy-agent binary for ${TARGET_ARCH} (${AGENT_RELEASE_ARCH})..."

    # Get the latest stable release from GitHub (excludes pre-releases)
    RELEASES_URL="https://api.github.com/repos/wendylabsinc/wendy-agent/releases/latest"

    # Fetch latest stable release
    wget -q -O ${B}/release.json "${RELEASES_URL}" || \
        curl -sL -o ${B}/release.json "${RELEASES_URL}" || \
        bbfatal "Failed to fetch latest release from GitHub"

    # Extract download URL for the target binary (match .tar.gz files only).
    # Asset naming: wendy-agent-linux-amd64-*.tar.gz or wendy-agent-linux-arm64-*.tar.gz
    DOWNLOAD_URL=$(cat ${B}/release.json | \
        grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*wendy-agent-linux-'"${AGENT_RELEASE_ARCH}"'[^"]*\.tar\.gz[^"]*"' | \
        head -1 | cut -d'"' -f4)

    if [ -z "${DOWNLOAD_URL}" ]; then
        bbfatal "Failed to find wendy-agent-linux-${AGENT_RELEASE_ARCH} binary in release"
    fi

    bbnote "Downloading from: ${DOWNLOAD_URL}"

    # Download the binary archive
    wget -O ${B}/wendy-agent.tar.gz "${DOWNLOAD_URL}" || \
        curl -L -o ${B}/wendy-agent.tar.gz "${DOWNLOAD_URL}" || \
        bbfatal "Failed to download wendy-agent binary"

    # Extract the archive
    tar -xzf ${B}/wendy-agent.tar.gz -C ${B}

    # Find and prepare the binary (exclude wendy-cli)
    if [ ! -f ${B}/wendy-agent ]; then
        BINARY=$(find ${B} -name wendy-agent -type f ! -path "*/wendy-cli*" | head -1)
        if [ -n "${BINARY}" ]; then
            mv "${BINARY}" ${B}/wendy-agent
        else
            bbfatal "wendy-agent binary not found in archive"
        fi
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
