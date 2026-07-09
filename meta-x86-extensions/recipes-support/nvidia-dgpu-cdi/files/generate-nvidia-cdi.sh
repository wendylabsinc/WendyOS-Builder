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

if [ ! -e /dev/nvidia0 ] && [ ! -e /dev/nvidiactl ]; then
    log "no NVIDIA device nodes found; skipping CDI generation"
    exit 0
fi

install -d -m 0755 /etc/cdi

if nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml; then
    chmod 0644 /etc/cdi/nvidia.yaml
    log "generated /etc/cdi/nvidia.yaml"
else
    log "failed to generate /etc/cdi/nvidia.yaml"
    exit 1
fi

nvidia-ctk cdi list 2>/dev/null || true
