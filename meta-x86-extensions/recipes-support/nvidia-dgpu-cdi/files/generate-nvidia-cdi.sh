#!/bin/sh
# Generate NVIDIA CDI metadata on x86 PCs when the proprietary driver and
# NVIDIA Container Toolkit are present.

set -eu

log() {
    echo "wendyos-nvidia-cdi: $*"
    logger -t wendyos-nvidia-cdi "$*" 2>/dev/null || true
}

if ! command -v nvidia-ctk >/dev/null 2>&1; then
    log "nvidia-ctk is not installed; skipping CDI generation"
    exit 0
fi

if [ ! -d /sys/module/nvidia ]; then
    log "nvidia kernel module not loaded; skipping CDI generation"
    exit 0
fi

# Create the device nodes. At boot they do not exist yet (loading the module
# does not create /dev nodes). nvidia-ctk makes the control nodes and ensures
# nvidia-uvm is loaded; nvidia-smi triggers nvidia-modprobe to create the
# per-GPU nodes (/dev/nvidia0).
nvidia-ctk system create-device-nodes --control-devices --load-kernel-modules \
    || log "create-device-nodes reported an error"
nvidia-smi >/dev/null 2>&1 || log "nvidia-smi probe failed (per-GPU nodes may be missing)"

install -d -m 0755 /etc/cdi

if nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml; then
    chmod 0644 /etc/cdi/nvidia.yaml
    log "generated /etc/cdi/nvidia.yaml"
else
    log "failed to generate /etc/cdi/nvidia.yaml"
    exit 1
fi

nvidia-ctk cdi list 2>/dev/null || true
