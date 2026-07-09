#!/bin/sh

set -u

REQUEST_FILE="/etc/wendyos/driver-request.conf"
REPO_FILE="/etc/yum.repos.d/wendyos-drivers.repo"
CONFIG_FILE="/usr/lib/wendyos/driver-installer.conf"
NVIDIA_DRIVER_PACKAGE="packagegroup-wendyos-nvidia-graphics"
ROCM_DRIVER_PACKAGE="packagegroup-wendyos-rocm"
INSTALL_AMD="0"
INSTALL_NVIDIA="0"
INSTALL_ROCM="0"

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

detect_amd_gpu() {
    for device_dir in /sys/bus/pci/devices/*; do
        [ -r "${device_dir}/vendor" ] || continue
        [ -r "${device_dir}/class" ] || continue

        class="$(cat "${device_dir}/class" 2>/dev/null || true)"
        case "$class" in
            0x03*) ;;
            *) continue ;;
        esac

        vendor="$(cat "${device_dir}/vendor" 2>/dev/null || true)"
        [ "$vendor" = "0x1002" ] && return 0
    done

    return 1
}

detect_supported_ryzen_rocm_apu() {
    cpu_model="$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1)"

    case "$cpu_model" in
        *"AMD Ryzen AI Max"*|\
        *"AMD Ryzen AI 9 HX 37"*|\
        *"AMD Ryzen AI 9 HX 47"*|\
        *"AMD Ryzen AI 9 365"*|\
        *"AMD Ryzen AI 9 465"*)
            log "detected ROCm-capable Ryzen APU candidate: ${cpu_model}"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

kernel_at_least() {
    required_major="$1"
    required_minor="$2"
    kernel_release="$(uname -r)"
    kernel_major="$(printf '%s\n' "$kernel_release" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')"
    kernel_minor="$(printf '%s\n' "$kernel_release" | sed -n 's/^[0-9][0-9]*\.\([0-9][0-9]*\).*/\1/p')"

    [ -n "$kernel_major" ] || return 1
    [ -n "$kernel_minor" ] || return 1

    [ "$kernel_major" -gt "$required_major" ] && return 0
    [ "$kernel_major" -eq "$required_major" ] && [ "$kernel_minor" -ge "$required_minor" ] && return 0
    return 1
}

rocm_preflight() {
    if ! detect_amd_gpu; then
        log "no AMD display controller detected; skipping ROCm install"
        return 1
    fi

    if detect_supported_ryzen_rocm_apu && ! kernel_at_least 6 14; then
        log "ROCm on Ryzen APUs requires a 6.14-1018 OEM-or-newer class kernel; current kernel is $(uname -r)"
        return 1
    fi

    if [ ! -e /dev/kfd ]; then
        log "/dev/kfd is not present; amdgpu compute support is not available"
        return 1
    fi

    if ! ls /dev/dri/renderD* >/dev/null 2>&1; then
        log "no DRM render node found; ROCm user access cannot be validated"
        return 1
    fi

    return 0
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

install_rocm_stack() {
    if ! rocm_preflight; then
        return 1
    fi

    log "checking WendyOS feed for ${ROCM_DRIVER_PACKAGE}"
    if ! dnf -q --disablerepo='*' --enablerepo='wendyos-drivers' list --available "$ROCM_DRIVER_PACKAGE" >/dev/null 2>&1 && \
       ! rpm -q "$ROCM_DRIVER_PACKAGE" >/dev/null 2>&1; then
        log "${ROCM_DRIVER_PACKAGE} is not available in the configured WendyOS driver feed"
        return 1
    fi

    dnf_driver_repo install "$ROCM_DRIVER_PACKAGE" || return 1

    if command -v usermod >/dev/null 2>&1 && id wendy >/dev/null 2>&1; then
        usermod -a -G render,video wendy 2>/dev/null || \
            log "could not add wendy to render/video groups; check group availability"
    fi

    if command -v rocminfo >/dev/null 2>&1; then
        if rocminfo >/var/log/wendyos-rocminfo.log 2>&1; then
            log "rocminfo validation succeeded"
        else
            log "rocminfo validation failed; see /var/log/wendyos-rocminfo.log"
            return 1
        fi
    else
        log "ROCm package installed but rocminfo is not present"
    fi
}

main() {
    load_config

    if [ "$INSTALL_AMD" != "1" ] && [ "$INSTALL_NVIDIA" != "1" ] && [ "$INSTALL_ROCM" != "1" ]; then
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
    if [ "$INSTALL_ROCM" = "1" ]; then
        install_rocm_stack || status=1
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
