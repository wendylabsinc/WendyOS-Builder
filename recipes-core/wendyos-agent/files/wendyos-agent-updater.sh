#!/bin/bash
#
# WendyOS Agent Auto-Updater Script
# Checks for and installs updates to the wendyos-agent binary
#

set -e

# Load configuration. /etc is on the A/B rootfs and is replaced wholesale by an
# OS OTA, so a pin written there is lost on the next `wendy os update`. /data is
# the only writable storage that survives a slot switch, so a copy there is read
# second and wins. Devices with no OTA stack (QEMU) have no /data and just skip
# it. Keep this list in sync with download-wendyos-agent.sh.
for conf in /etc/default/wendy-agent /data/etc/default/wendy-agent; do
    if [ -f "${conf}" ]; then
        # shellcheck source=/dev/null
        source "${conf}"
    fi
done

# Default values if not configured.
#
# WENDYOS_AGENT_VERSION pins the agent to one release tag (e.g.
# "2026.07.27-081952"); "latest" tracks the newest stable release. A pin is an
# operator override and is honoured exactly, including installing an OLDER
# build than the one running -- that is the point of it. See check_update.
#
# Not to be confused with the WENDYOS_AGENT_VERSION in wendyos-agent_1.0.bb,
# which is a build-time pin for the binary baked into the image. This one is
# runtime only, read from /etc/default/wendy-agent.
GITHUB_REPO="${WENDYOS_AGENT_GITHUB_REPO:-wendylabsinc/wendy-agent}"
VERSION="${WENDYOS_AGENT_VERSION:-latest}"

# Paths
INSTALL_DIR="/usr/local/bin"
BACKUP_DIR="/opt/wendy/bin"
BINARY_NAME="wendy-agent"
VERSION_FILE="/var/lib/wendy-agent/current-version"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    logger -t wendyos-agent-updater "$*"
}

error() {
    log "ERROR: $*" >&2
    exit 1
}

# Check network connectivity
check_network() {
    log "Checking network connectivity"

    # Try to ping GitHub
    if ! curl -s --head --connect-timeout 5 https://api.github.com >/dev/null 2>&1; then
        log "No network connectivity to GitHub, skipping update check"
        exit 0
    fi
}

# Get the version string reported by the installed binary. `wendy-agent
# --version` prints exactly the build's version.Version on its own line (e.g.
# "dev", "2026.06.30-133859-dev", "2026.07.27-081952"). It is used verbatim:
# agent versions are YYYY.MM.DD-HHMMSS, so extracting a semver-shaped prefix
# drops the time and makes every build cut on a given day compare equal --
# which downgrades a same-day nightly onto stable and reinstalls stable over
# itself forever (WDY-2038). Falls back to the stored version file only if the
# binary will not run.
get_current_version() {
    local current_version=""

    if [ -f "${INSTALL_DIR}/${BINARY_NAME}" ] && "${INSTALL_DIR}/${BINARY_NAME}" --version >/dev/null 2>&1; then
        current_version=$("${INSTALL_DIR}/${BINARY_NAME}" --version 2>&1 | head -1 | tr -d '[:space:]')
    elif [ -f "${VERSION_FILE}" ]; then
        current_version=$(head -1 "${VERSION_FILE}" | tr -d '[:space:]')
    fi

    echo "${current_version}"
}

# Report whether a version string is a development build. Mirrors version.IsDev
# in the Go CLI (WDY-1770): a dev build is the literal "dev" default or any CI
# branch build carrying the "-dev" suffix (e.g. "2026.06.30-133859-dev"). Dev
# builds are treated as the latest version and must never be overwritten by the
# on-boot auto-updater, so developers debugging against a dev/branch build keep
# it instead of getting silently replaced with the latest stable release.
is_dev_build() {
    case "$1" in
        dev|*-dev) return 0 ;;
        *) return 1 ;;
    esac
}

# Get latest stable version from GitHub (excludes pre-releases)
get_latest_version() {
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

    # Get the latest stable release
    local release_info
    if command -v wget >/dev/null 2>&1; then
        release_info=$(wget -q -O - "${api_url}" 2>/dev/null) || return 1
    else
        release_info=$(curl -sL "${api_url}" 2>/dev/null) || return 1
    fi

    # Extract version tag (format: vX.Y.Z)
    local latest_version
    if command -v jq >/dev/null 2>&1; then
        latest_version=$(echo "${release_info}" | jq -r '.tag_name // empty')
    else
        latest_version=$(echo "${release_info}" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    # Remove 'v' prefix for version comparison (v1.0.0 -> 1.0.0)
    latest_version="${latest_version#v}"

    echo "${latest_version}"
}

# Resolve the version this device should be running: the pin when one is set,
# otherwise the newest stable release.
get_target_version() {
    if [ "${VERSION}" != "latest" ]; then
        echo "${VERSION#v}"
        return 0
    fi

    get_latest_version
}

# Report whether version1 is strictly newer than version2. Mirrors
# version.CompareVersions in the Go CLI: split on "." and "-", compare fields
# numerically when both sides are numeric and lexicographically otherwise, so
# "2026.07.27-081952" > "2026.07.27-003050". Arithmetic rather than `sort -V`
# so shell and Go agree, and so there is no capability probe whose failure
# branch treated "any difference" as "newer".
version_gt() {
    local version1="${1#v}"
    local version2="${2#v}"

    if [ -z "${version1}" ] || [ -z "${version2}" ] || [ "${version1}" = "${version2}" ]; then
        return 1
    fi

    local a b n i ap bp
    IFS='.-' read -r -a a <<< "${version1}"
    IFS='.-' read -r -a b <<< "${version2}"

    n=${#a[@]}
    if [ "${#b[@]}" -gt "${n}" ]; then
        n=${#b[@]}
    fi

    for ((i = 0; i < n; i++)); do
        ap="${a[i]:-0}"
        bp="${b[i]:-0}"
        if [ "${ap}" = "${bp}" ]; then
            continue
        fi
        # 10# forces base 10: agent timestamps like 081952 are not valid octal.
        if [[ "${ap}" =~ ^[0-9]+$ && "${bp}" =~ ^[0-9]+$ ]]; then
            if [ "$((10#${ap}))" -gt "$((10#${bp}))" ]; then return 0; else return 1; fi
        fi
        if [[ "${ap}" > "${bp}" ]]; then return 0; else return 1; fi
    done

    return 1
}

# Check if update is needed
check_update() {
    local current_version target_version
    current_version=$(get_current_version)
    target_version=$(get_target_version)

    if [ -z "${target_version}" ]; then
        log "Could not determine target version"
        return 1
    fi

    log "Current version: ${current_version:-unknown}"

    # Pinned: converge on exactly this tag. An explicit pin outranks the
    # never-go-backwards rule below, so this WILL install an older build --
    # that is what a pin is for (e.g. holding a fleet on a known-good agent
    # while a regression is investigated).
    if [ "${VERSION}" != "latest" ]; then
        log "Pinned version: ${target_version}"
        if [ "${current_version#v}" = "${target_version}" ]; then
            log "Already at the pinned version"
            return 1
        fi
        log "Pin mismatch: ${current_version:-unknown} -> ${target_version}"
        return 0
    fi

    log "Latest stable version: ${target_version}"

    if [ -z "${current_version}" ]; then
        log "No current version found, update needed"
        return 0
    fi

    if version_gt "${target_version}" "${current_version}"; then
        log "Update available: ${current_version} -> ${target_version}"
        return 0
    else
        log "Already up to date"
        return 1
    fi
}

# Perform update
perform_update() {
    log "Starting wendyos-agent update"

    # Stop the service if running
    if systemctl is-active --quiet wendyos-agent.service; then
        log "Stopping wendyos-agent service"
        systemctl stop wendyos-agent.service
    fi

    # Run the download script
    if /opt/wendyos/bin/download-wendyos-agent.sh; then
        log "Update completed successfully"

        # Store the new version
        mkdir -p "$(dirname "${VERSION_FILE}")"
        get_target_version > "${VERSION_FILE}"

        # Restart the service if it was running
        if systemctl is-enabled --quiet wendyos-agent.service; then
            log "Starting wendyos-agent service"
            systemctl start wendyos-agent.service
        fi

        return 0
    else
        log "Update failed"

        # Try to restore from backup if available
        if [ -f "${BACKUP_DIR}/${BINARY_NAME}.latest" ]; then
            log "Restoring from backup"
            cp "${BACKUP_DIR}/${BINARY_NAME}.latest" "${INSTALL_DIR}/${BINARY_NAME}"
            chmod 755 "${INSTALL_DIR}/${BINARY_NAME}"
        fi

        # Restart the service if it was running
        if systemctl is-enabled --quiet wendyos-agent.service; then
            systemctl start wendyos-agent.service
        fi

        return 1
    fi
}

# Main execution
main() {
    log "Starting wendy-agent update check"

    # Check network connectivity first
    check_network

    # Check if binary exists at all
    if [ ! -f "${INSTALL_DIR}/${BINARY_NAME}" ]; then
        log "Wendy-agent not installed, performing initial download"
        perform_update
        exit $?
    fi

    # Never overwrite a dev build (WDY-1770). A developer deliberately installed
    # a dev/branch build to debug against; the auto-updater must leave it in
    # place rather than replacing it with the latest stable release. This
    # mirrors the CLI/Agent fix that stops prompting/pushing such overwrites.
    local raw_version
    raw_version=$(get_current_version)
    if is_dev_build "${raw_version}"; then
        log "Installed agent is a dev build (${raw_version:-unknown}), skipping auto-update"
        exit 0
    fi

    # Check if update is needed
    if check_update; then
        perform_update
        exit $?
    else
        log "No update needed"
        exit 0
    fi
}

# Run main function, unless sourced by the unit tests, which want the
# functions without the update check firing.
if [ -z "${WENDYOS_UPDATER_LIB_ONLY:-}" ]; then
    main "$@"
fi
