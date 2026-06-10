#!/bin/sh

set -u

TARGET_ROOT="${1:-/tgt_root}"
REQUEST_DIR="${TARGET_ROOT}/etc/wendyos"
REQUEST_FILE="${REQUEST_DIR}/driver-request.conf"

read_answer() {
    prompt="$1"
    var_name="$2"

    printf "%s" "$prompt"
    IFS= read -r answer || answer=""
    eval "$var_name=\$answer"
}

yes_selected() {
    case "$1" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

detect_gpu_vendor() {
    vendor_id="$1"

    for device_dir in /sys/bus/pci/devices/*; do
        [ -r "${device_dir}/vendor" ] || continue
        [ -r "${device_dir}/class" ] || continue

        class="$(cat "${device_dir}/class" 2>/dev/null || true)"
        case "$class" in
            0x03*) ;;
            *) continue ;;
        esac

        vendor="$(cat "${device_dir}/vendor" 2>/dev/null || true)"
        if [ "$vendor" = "$vendor_id" ]; then
            return 0
        fi
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
            echo "$cpu_model"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

write_request() {
    install_amd="$1"
    install_nvidia="$2"
    install_rocm="$3"

    mkdir -p "$REQUEST_DIR"
    umask 077
    {
        echo "INSTALL_AMD=\"${install_amd}\""
        echo "INSTALL_NVIDIA=\"${install_nvidia}\""
        echo "INSTALL_ROCM=\"${install_rocm}\""
        echo "REQUEST_SOURCE=\"installer\""
    } > "$REQUEST_FILE"
    chmod 0600 "$REQUEST_FILE"
}

echo
echo "Checking for AMD/NVIDIA graphics hardware..."

detected_amd=0
detected_nvidia=0
detect_gpu_vendor "0x1002" && detected_amd=1
detect_gpu_vendor "0x10de" && detected_nvidia=1

if [ "$detected_amd" != "1" ] && [ "$detected_nvidia" != "1" ]; then
    echo "No AMD or NVIDIA display controller was detected."
    exit 0
fi

if [ ! -x "${TARGET_ROOT}/usr/sbin/wendyos-driver-update.sh" ]; then
    echo "Driver update helper is not installed in the target rootfs; skipping."
    exit 0
fi

install_amd=0
install_nvidia=0
install_rocm=0

if [ "$detected_amd" = "1" ]; then
    echo "Detected AMD graphics hardware."
    read_answer "Schedule AMD graphics/firmware update from WendyOS feed after first boot? [y/N]: " answer_amd
    if yes_selected "$answer_amd"; then
        install_amd=1
    fi

    if rocm_apu="$(detect_supported_ryzen_rocm_apu)"; then
        echo "Detected ROCm-capable Ryzen APU candidate: ${rocm_apu}"
        echo "ROCm requires a WendyOS ROCm feed package and a supported kernel."
        read_answer "Schedule ROCm/HIP runtime install from WendyOS feed after first boot? [y/N]: " answer_rocm
        if yes_selected "$answer_rocm"; then
            install_rocm=1
        fi
    else
        echo "No AMD Ryzen AI/AI Max ROCm APU was detected; ROCm auto-install will not be scheduled."
    fi
fi

if [ "$detected_nvidia" = "1" ]; then
    echo "Detected NVIDIA graphics hardware."
    echo "The built-in Nouveau driver remains available as a fallback."
    echo "Official NVIDIA support requires a WendyOS driver package built for this kernel."
    read_answer "Schedule official NVIDIA driver install from WendyOS feed after first boot? [y/N]: " answer_nvidia
    if yes_selected "$answer_nvidia"; then
        install_nvidia=1
    fi
fi

if [ "$install_amd" != "1" ] && [ "$install_nvidia" != "1" ] && [ "$install_rocm" != "1" ]; then
    echo "Skipping GPU driver update scheduling."
    exit 0
fi

write_request "$install_amd" "$install_nvidia" "$install_rocm"

if [ -r "${TARGET_ROOT}/etc/yum.repos.d/wendyos-drivers.repo" ]; then
    echo "Driver update request saved. WendyOS will download updates on first boot after networking is online."
else
    echo "Driver update request saved, but this image has no WendyOS driver feed configured yet."
    echo "Add a feed via WENDYOS_DRIVER_FEED_URI to enable automatic downloads."
fi
