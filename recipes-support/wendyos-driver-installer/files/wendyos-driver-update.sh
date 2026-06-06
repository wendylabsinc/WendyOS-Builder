#!/bin/sh

set -u

REQUEST_FILE="/etc/wendyos/driver-request.conf"
REPO_FILE="/etc/yum.repos.d/wendyos-drivers.repo"
CONFIG_FILE="/usr/lib/wendyos/driver-installer.conf"
NVIDIA_DRIVER_PACKAGE="packagegroup-wendyos-nvidia-graphics"
INSTALL_AMD="0"
INSTALL_NVIDIA="0"

log() {
    echo "wendyos-driver-update: $*"
    logger -t wendyos-driver-update "$*" 2>/dev/null || true
}

load_config() {
    [ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
    [ -r "$REQUEST_FILE" ] && . "$REQUEST_FILE"
}

has_driver_repo() {
    [ -r "$REPO_FILE" ] && grep -q '^enabled=1' "$REPO_FILE"
}

dnf_driver_repo() {
    dnf -y --disablerepo='*' --enablerepo='wendyos-drivers' "$@"
}

installed_package_list() {
    kernel_release="$(uname -r)"

    for package_name in \
        linux-firmware \
        linux-firmware-amdgpu \
        mesa \
        libdrm \
        vulkan-loader \
        mesa-vulkan-drivers \
        "kernel-module-amdgpu-${kernel_release}" \
        "kernel-module-radeon-${kernel_release}"
    do
        if rpm -q "$package_name" >/dev/null 2>&1; then
            printf '%s\n' "$package_name"
        fi
    done
}

update_amd_stack() {
    packages="$(installed_package_list | tr '\n' ' ')"
    if [ -z "$packages" ]; then
        log "no installed AMD graphics packages matched the update set"
        return 0
    fi

    log "checking WendyOS feed for AMD graphics/firmware updates"
    # shellcheck disable=SC2086
    dnf_driver_repo upgrade --refresh $packages
}

install_nvidia_stack() {
    log "checking WendyOS feed for ${NVIDIA_DRIVER_PACKAGE}"
    if ! dnf -q --disablerepo='*' --enablerepo='wendyos-drivers' list --available "$NVIDIA_DRIVER_PACKAGE" >/dev/null 2>&1 && \
       ! rpm -q "$NVIDIA_DRIVER_PACKAGE" >/dev/null 2>&1; then
        log "${NVIDIA_DRIVER_PACKAGE} is not available in the configured WendyOS driver feed"
        return 1
    fi

    dnf_driver_repo install "$NVIDIA_DRIVER_PACKAGE"
}

main() {
    load_config

    if [ "$INSTALL_AMD" != "1" ] && [ "$INSTALL_NVIDIA" != "1" ]; then
        log "no driver update request found"
        return 0
    fi

    if ! command -v dnf >/dev/null 2>&1 || ! command -v rpm >/dev/null 2>&1; then
        log "dnf/rpm are not available; cannot install feed-backed driver updates"
        return 0
    fi

    if ! has_driver_repo; then
        log "no enabled WendyOS driver feed is configured at ${REPO_FILE}"
        return 0
    fi

    status=0
    if [ "$INSTALL_AMD" = "1" ]; then
        update_amd_stack || status=1
    fi
    if [ "$INSTALL_NVIDIA" = "1" ]; then
        install_nvidia_stack || status=1
    fi

    if [ "$status" -eq 0 ]; then
        rm -f "$REQUEST_FILE"
        log "driver update request completed"
    else
        log "driver update request did not complete; it will be retried on next boot"
    fi

    return 0
}

main "$@"
