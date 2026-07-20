#!/bin/sh
# WendyOS GPU container-compute setup. At boot, detect which GPU vendor(s) are
# present, load the matching kernel modules on demand, and generate the
# container CDI spec. Part of the single-image GPU strategy for the x86 fleet
# (docs/plans/x86-support-plan.md). Phase A: the NVIDIA/CUDA branch is live, the
# AMD/ROCm branch is a Phase C stub.

set -eu

log() {
    echo "wendyos-gpu-cdi: $*"
    logger -t wendyos-gpu-cdi "$*" 2>/dev/null || true
}

# Find the PCI vendor of every display-class device. Class 0x03xxxx covers
# 0300 (VGA), 0302 (3D controller, common for laptop dGPUs) and 0380 (display
# other). Read straight from sysfs so we do not depend on lspci.
have_nvidia=0
have_amd=0
for dev in /sys/bus/pci/devices/*; do
    [ -r "$dev/class" ] && [ -r "$dev/vendor" ] || continue
    class=$(cat "$dev/class")
    case "$class" in
        0x03*) ;;
        *) continue ;;
    esac

    vendor=$(cat "$dev/vendor")
    case "$vendor" in
        0x10de) have_nvidia=1 ;;
        0x1002) have_amd=1 ;;
    esac
done

setup_nvidia() {
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
        log "NVIDIA GPU present but nvidia-ctk is not installed, skipping"
        return 0
    fi

    # Load the compute modules on demand (they are not autoloaded at boot), then
    # create the control nodes. The /dev nodes do not exist until something
    # creates them, and nvidia-smi triggers nvidia-modprobe to make the per-GPU
    # nodes.
    modprobe nvidia nvidia-uvm || log "modprobe of nvidia/nvidia-uvm failed"
    nvidia-ctk system create-device-nodes --control-devices --load-kernel-modules \
        || log "create-device-nodes reported an error"
    nvidia-smi >/dev/null 2>&1 || log "nvidia-smi probe failed (per-GPU nodes may be missing)"

    install -d -m 0755 /etc/cdi
    if nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml; then
        chmod 0644 /etc/cdi/nvidia.yaml
        log "generated /etc/cdi/nvidia.yaml"
    else
        log "failed to generate /etc/cdi/nvidia.yaml"
        return 1
    fi

    nvidia-ctk cdi list 2>/dev/null || true
}

setup_amd() {
    # Phase C: pull the ROCm userspace from the driver feed and generate an AMD
    # CDI spec (amd-ctk cdi generate, or inject /dev/kfd + /dev/dri). amdgpu and
    # amdkfd already autoload in-tree, so display works without any of this.
    log "AMD GPU detected, ROCm container-compute is not yet implemented (Phase C)"
}

if [ "$have_nvidia" = 1 ]; then
    log "NVIDIA GPU detected, setting up CUDA container compute"
    setup_nvidia
elif [ "$have_amd" = 1 ]; then
    setup_amd
else
    log "no NVIDIA or AMD GPU detected, nothing to configure"
fi

exit 0
