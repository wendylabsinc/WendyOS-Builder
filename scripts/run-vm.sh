#!/usr/bin/env bash
#
# Launch a WendyOS VM image (vm-x86-64-wendyos) under QEMU.
#
# Supersedes run-qemu.sh for the VM machines. The differences are deliberate:
# run-qemu.sh boots a kernel+rootfs directly on a host bridge for the old
# qemuarm64 dev loop; this boots the real UEFI/GPT disk image through OVMF and
# the A/B GRUB chain, so the guest exercises the same boot path a device does.
#
# Each VM is a named instance: one read-only .wic base shared by N qcow2
# overlays, so a clone costs a few hundred KB and a second. That is what makes
# the ML-training loop ("user code in the loop", many cheap instances) practical.
#
# See docs/plans/vm-support-plan.md.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global flags
VERBOSE=false
DRY_RUN=false
RECREATE=false

# Configuration (all overridable by flag; BUILD_DIR also by environment)
BUILD_DIR="${BUILD_DIR:-build}"
MACHINE="vm-x86-64-wendyos"
NAME="default"
DISK_GROW="32G"
MEMORY="4096"
CPUS="4"
SSH_PORT=""
EXTRA_ARGS=()

# --- arch-varying values ------------------------------------------------------
# x86_64 only for now. Phase 2 (arm64) adds a second column here rather than a
# second script: qemu-system-aarch64, AAVMF_CODE/VARS instead of OVMF, and
# -machine virt instead of q35. Everything below this block is arch-neutral.
QEMU_BIN="qemu-system-x86_64"
QEMU_MACHINE="q35"
# Firmware CODE/VARS pairs, most preferred first. The _4M pair is what Debian 13
# and Ubuntu ship. Deliberately NOT matched: *.secboot.fd / *_MS.fd — those
# enroll Microsoft's Secure Boot keys and would refuse our unsigned GRUB.
FIRMWARE_PAIRS=(
    "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd"
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
    "/usr/share/qemu/ovmf-x86_64-code.bin:/usr/share/qemu/ovmf-x86_64-vars.bin"
)

# Print formatted/colored output
info() { printf "%b\n" "$*"; }
success() { printf "%b%s%b\n" "${GREEN}" "$*" "${NC}"; }
warning() { printf "%bWARNING%b: %s\n" "${YELLOW}" "${NC}" "$*"; }
error() { printf "%bERROR%b: %s\n" "${RED}" "${NC}" "$*" >&2; }
debug() {
    if [[ "${VERBOSE}" == "true" ]]; then
        printf "%bDEBUG%b: %s\n" "${BLUE}" "${NC}" "$*" >&2
    fi
}

# Execute a command, with dry-run support
execute() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf "%bDRY-RUN%b: %s\n" "${YELLOW}" "${NC}" "$*"
        return 0
    fi
    eval "$*"
}

check_command() { command -v "$1" &> /dev/null; }

show_usage() {
    cat << EOF
Usage: $0 [options] [-- extra qemu args]

Launch a WendyOS VM image under QEMU/KVM with UEFI firmware.

Options:
    -n, --name NAME      Instance name (default: default). Each instance gets its
                         own disk overlay and UEFI variables, so several can run
                         at once from one shared base image.
    -b, --build-dir DIR  Build directory (default: build)
    -m, --machine NAME   Yocto MACHINE (default: ${MACHINE})
        --memory MB      Guest RAM in MB (default: ${MEMORY})
        --cpus N         Guest vCPUs (default: ${CPUS})
        --disk-size SIZE Grow the virtual disk by this much on creation
                         (default: ${DISK_GROW}). Required: the .wic is exactly
                         the size of its partitions, so without headroom /data
                         cannot grow on first boot.
        --ssh-port PORT  Host port forwarded to guest :22 (default: first free
                         port from 2222 up)
        --recreate       Delete and recreate this instance's disk and UEFI
                         variables. Gives a fresh device identity.
    -v, --verbose        Verbose/debug output
        --dry-run        Print what would be done, run nothing
    -h, --help           Show this help

Environment:
    BUILD_DIR            Build directory path (default: build)

Examples:
    $0                                  # boot the default instance
    $0 --name train-01                  # a second, independent VM
    $0 --name train-01 --recreate       # wipe it back to a first boot
    $0 --memory 8192 --cpus 8           # bigger guest
    $0 --dry-run --verbose              # show the qemu command line
    $0 -- -device usb-tablet            # append raw qemu arguments

Shutting down cleanly:
    Run 'poweroff' in the guest, or press Ctrl-A then C for the QEMU monitor and
    type 'system_powerdown'. Do NOT use Ctrl-A X — that kills the VM instantly,
    which can leave an in-progress A/B update half-applied.

Notes:
    - The guest reaches host services at 10.0.2.2 (QEMU user networking). That
      address is virtual and never appears in 'ip addr' on the host.
    - Instance state lives in <workspace>/vm/<name>/.
EOF
}

# Locate the newest real .wic in the deploy directory.
#
# Deliberately skips symlinks: every build repoints wendyos-image-*.rootfs.wic at
# its newest output, and a qcow2 overlay records the path it was given. Backing an
# overlay with the symlink means the next build silently swaps the disk under a
# running VM. Always bind to the timestamped file.
find_base_image() {
    local deploy_dir="$1"
    local newest

    if [[ ! -d "${deploy_dir}" ]]; then
        error "Deploy directory not found: ${deploy_dir}"
        error "Build the image first, or pass --build-dir / --machine."
        return 1
    fi

    newest=$(find "${deploy_dir}" -maxdepth 1 -name '*.wic' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)

    if [[ -z "${newest}" ]]; then
        error "No .wic image in ${deploy_dir}"
        return 1
    fi

    realpath "${newest}"
}

# Pick the first firmware pair present on this host.
find_firmware() {
    local pair code vars
    for pair in "${FIRMWARE_PAIRS[@]}"; do
        code="${pair%%:*}"
        vars="${pair##*:}"
        if [[ -r "${code}" && -r "${vars}" ]]; then
            debug "firmware: ${code} + ${vars}"
            printf '%s\n' "${pair}"
            return 0
        fi
    done
    error "No UEFI firmware found. Install OVMF:"
    error "  Debian/Ubuntu: sudo apt install ovmf"
    error "  Fedora:        sudo dnf install edk2-ovmf"
    error "Looked for: ${FIRMWARE_PAIRS[*]}"
    return 1
}

# First free TCP port at or above $1, so two instances never collide.
find_free_port() {
    local port="$1"
    local limit=$((port + 100))
    while [[ "${port}" -lt "${limit}" ]]; do
        if check_command ss; then
            if ! ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; then
                printf '%s\n' "${port}"
                return 0
            fi
        else
            # No ss: assume free and let qemu report a bind failure.
            printf '%s\n' "${port}"
            return 0
        fi
        port=$((port + 1))
    done
    error "No free port in $1..${limit}"
    return 1
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)       NAME="$2"; shift 2 ;;
            -b|--build-dir)  BUILD_DIR="$2"; shift 2 ;;
            -m|--machine)    MACHINE="$2"; shift 2 ;;
            --memory)        MEMORY="$2"; shift 2 ;;
            --cpus)          CPUS="$2"; shift 2 ;;
            --disk-size)     DISK_GROW="$2"; shift 2 ;;
            --ssh-port)      SSH_PORT="$2"; shift 2 ;;
            --recreate)      RECREATE=true; shift ;;
            -v|--verbose)    VERBOSE=true; shift ;;
            --dry-run)       DRY_RUN=true; shift ;;
            -h|--help)       show_usage; exit 0 ;;
            --)              shift; EXTRA_ARGS=("$@"); break ;;
            *)
                error "Unknown argument: $1"
                echo ""
                show_usage
                exit 1
                ;;
        esac
    done

    local script_dir workspace_dir deploy_dir base_image
    local state_dir overlay nvram fw_pair fw_code fw_vars
    local accel cpu_model

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    workspace_dir="$(cd "${script_dir}/../.." && pwd)"
    deploy_dir="${workspace_dir}/${BUILD_DIR}/tmp/deploy/images/${MACHINE}"

    for tool in "${QEMU_BIN}" qemu-img; do
        check_command "${tool}" || { error "Required tool not found: ${tool}"; exit 1; }
    done

    base_image="$(find_base_image "${deploy_dir}")" || exit 1
    fw_pair="$(find_firmware)" || exit 1
    fw_code="${fw_pair%%:*}"
    fw_vars="${fw_pair##*:}"

    state_dir="${workspace_dir}/vm/${NAME}"
    overlay="${state_dir}/disk.qcow2"
    nvram="${state_dir}/OVMF_VARS.fd"

    info "Instance:  ${NAME}"
    info "Base image: ${base_image}"
    info "State:     ${state_dir}"

    # Decide from intent, not from what is on disk after the fact: under --dry-run
    # the rm below does not actually happen, so re-reading the filesystem would
    # send a --recreate dry run down the "instance already exists" path and print
    # the opposite of what a real run would do.
    local needs_create=false
    if [[ ! -e "${overlay}" ]]; then
        needs_create=true
    elif [[ "${RECREATE}" == "true" ]]; then
        warning "Recreating ${NAME}: existing disk and UEFI variables are discarded."
        execute "rm -f '${overlay}' '${nvram}'"
        needs_create=true
    fi

    execute "mkdir -p '${state_dir}'"

    if [[ "${needs_create}" == "true" ]]; then
        info "Creating disk overlay (+${DISK_GROW} headroom for /data)"
        # Absolute backing path: qemu-img resolves a relative one against the
        # OVERLAY's directory, not the working directory.
        execute "qemu-img create -f qcow2 -F raw -b '${base_image}' '${overlay}' >/dev/null"
        # The .wic ends one sector after its last partition, so /data has nowhere
        # to grow into. grow-data-part runs on first boot and needs this headroom.
        execute "qemu-img resize '${overlay}' '+${DISK_GROW}' >/dev/null"
        execute "cp '${fw_vars}' '${nvram}'"
    else
        # Warn if the base moved on: a rebuild writes a new timestamped .wic, and
        # this overlay stays bound to the one it was created from.
        local bound
        bound="$(qemu-img info --output=json "${overlay}" 2>/dev/null \
            | sed -n 's/.*"full-backing-filename": *"\([^"]*\)".*/\1/p' | head -1)"
        if [[ -n "${bound}" && "${bound}" != "${base_image}" ]]; then
            warning "Instance ${NAME} is bound to an older image:"
            warning "  ${bound}"
            warning "Newest build is:"
            warning "  ${base_image}"
            warning "Use --recreate to move this instance to the new image."
        fi
    fi

    if [[ -w /dev/kvm ]]; then
        accel="kvm"
        # -cpu host: genericx86-64 is tuned for x86-64-v3 (AVX2/BMI/FMA), so the
        # default qemu64 model cannot run the image at all. See plan 4.1.
        cpu_model="host"
    else
        accel="tcg"
        cpu_model="Skylake-Client"
        warning "/dev/kvm not available — falling back to software emulation (slow)."
        warning "Add yourself to the 'kvm' group to fix this."
    fi
    debug "accel=${accel} cpu=${cpu_model}"

    if [[ -z "${SSH_PORT}" ]]; then
        SSH_PORT="$(find_free_port 2222)" || exit 1
    fi

    info "SSH:       ssh -p ${SSH_PORT} wendy@localhost"
    info ""
    success "Starting ${NAME} (${CPUS} vCPU, ${MEMORY} MB, ${accel})."
    info "Exit cleanly with 'poweroff' in the guest, or Ctrl-A C then 'system_powerdown'."
    info ""

    local -a qemu_cmd=(
        "${QEMU_BIN}"
        -machine "${QEMU_MACHINE},accel=${accel}"
        -cpu "${cpu_model}"
        -smp "${CPUS}"
        -m "${MEMORY}"
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=${fw_code}"
        -drive "if=pflash,format=raw,unit=1,file=${nvram}"
        -drive "if=virtio,format=qcow2,file=${overlay}"
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
        -device "virtio-net-pci,netdev=net0"
        -object "rng-random,filename=/dev/urandom,id=rng0"
        -device "virtio-rng-pci,rng=rng0"
        -nographic
    )
    qemu_cmd+=("${EXTRA_ARGS[@]}")

    if [[ "${DRY_RUN}" == "true" ]]; then
        printf "%bDRY-RUN%b: %s\n" "${YELLOW}" "${NC}" "${qemu_cmd[*]}"
        exit 0
    fi

    exec "${qemu_cmd[@]}"
}

main "$@"
