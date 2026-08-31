#!/usr/bin/env bash
#
# Launch a WendyOS VM image (vm-x86-64-wendyos or vm-arm64-wendyos) under QEMU.
#
# Supersedes run-qemu.sh for the VM machines. The differences are deliberate:
# run-qemu.sh boots a kernel+rootfs directly on a host bridge for the old
# qemuarm64 dev loop; this boots the real UEFI/GPT disk image through UEFI
# firmware and the A/B GRUB chain, so the guest exercises the same boot path a
# device does.
#
# Either machine runs on either host. A guest whose architecture differs from the
# host falls back to TCG emulation -- slow, but it exercises the real boot chain,
# which is how the arm64 image can be tested without an arm64 machine.
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

BIOS=""

# --- arch-varying values ------------------------------------------------------
# Everything outside select_arch() is architecture-neutral. Adding a third VM
# machine means adding a case here, not touching the rest of the script.
#
# Firmware is a CODE/VARS pflash pair in both cases. Deliberately NOT matched:
# *.secboot.fd, *_MS.fd, AAVMF_CODE.ms.fd -- those enroll Microsoft's Secure Boot
# keys and would refuse our unsigned GRUB. That trap applies equally on both
# arches, which is why the preferred entry is explicitly the no-secboot build.
#
# UNVERIFIED (macOS): the Homebrew firmware paths below have not been run on a
# Mac. They assume Homebrew's qemu installs QEMU's own pc-bios/edk2-*.fd set into
# $(brew --prefix)/share/qemu -- /opt/homebrew on Apple Silicon, /usr/local on
# Intel. Debian splits that firmware into separate ovmf/AAVMF packages, so the
# naming could not be confirmed from the development host. If a Mac reports "No
# UEFI firmware found", check `ls $(brew --prefix)/share/qemu/edk2-*` and correct
# these two entries; nothing else in the script depends on the names.
select_arch() {
    case "${MACHINE}" in
        vm-x86-64-wendyos)
            GUEST_ARCH="x86_64"
            QEMU_BIN="qemu-system-x86_64"
            QEMU_MACHINE="q35"
            # genericx86-64 is tuned for x86-64-v3 (AVX2/BMI/FMA), so the default
            # qemu64 model cannot run the image at all. See plan 4.1.
            CPU_KVM="host"
            CPU_TCG="Skylake-Client"
            FIRMWARE_PAIRS=(
                "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd"
                "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"
                "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
                "/usr/share/qemu/ovmf-x86_64-code.bin:/usr/share/qemu/ovmf-x86_64-vars.bin"
            )
            FIRMWARE_PAIRS+=(
                # macOS/Homebrew. UNVERIFIED — see the note above select_arch.
                "/opt/homebrew/share/qemu/edk2-x86_64-code.fd:/opt/homebrew/share/qemu/edk2-i386-vars.fd"
                "/usr/local/share/qemu/edk2-x86_64-code.fd:/usr/local/share/qemu/edk2-i386-vars.fd"
            )
            FIRMWARE_HINT="Debian/Ubuntu: sudo apt install ovmf   |   macOS: brew install qemu"
            ;;
        vm-arm64-wendyos)
            GUEST_ARCH="aarch64"
            QEMU_BIN="qemu-system-aarch64"
            QEMU_MACHINE="virt"
            # cortex-a76 is what genericarm64's own runqemu config emulates
            # (QB_CPU). There is no minimum feature level to satisfy the way
            # x86-64-v3 constrains the x86 machine.
            CPU_KVM="host"
            CPU_TCG="cortex-a76"
            FIRMWARE_PAIRS=(
                "/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd:/usr/share/AAVMF/AAVMF_VARS.fd"
                "/usr/share/AAVMF/AAVMF_CODE.fd:/usr/share/AAVMF/AAVMF_VARS.fd"
                "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw:/usr/share/edk2/aarch64/vars-template-pflash.raw"
            )
            FIRMWARE_PAIRS+=(
                # macOS/Homebrew. UNVERIFIED — see the note above select_arch.
                "/opt/homebrew/share/qemu/edk2-aarch64-code.fd:/opt/homebrew/share/qemu/edk2-arm-vars.fd"
                "/usr/local/share/qemu/edk2-aarch64-code.fd:/usr/local/share/qemu/edk2-arm-vars.fd"
            )
            FIRMWARE_HINT="Debian/Ubuntu: sudo apt install qemu-efi-aarch64 qemu-system-arm   |   macOS: brew install qemu"
            ;;
        *)
            error "Unknown machine: ${MACHINE}"
            error "Known: vm-x86-64-wendyos, vm-arm64-wendyos"
            return 1
            ;;
    esac
}

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

# --- portability helpers -------------------------------------------------------
# This script runs on Linux and macOS. macOS ships BSD userland, so three things
# used elsewhere are unavailable: `find -printf`, `ss`, and `realpath`. Each is
# replaced below rather than assumed.

# Normalise `uname -m` to the names QEMU uses for a guest architecture.
# macOS on Apple Silicon reports "arm64" where Linux reports "aarch64" -- without
# this the host/guest comparison never matches on a Mac and every guest would be
# needlessly emulated on the one host where it should run natively.
norm_arch() {
    case "$1" in
        arm64|aarch64)
            printf 'aarch64\n'
            ;;
        x86_64|amd64)
            printf 'x86_64\n'
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

# Absolute path of a file, without realpath(1) (absent from base macOS).
# The qcow2 overlay stores this, and a relative backing path would resolve
# against the overlay's own directory.
abs_path() {
    local dir base
    dir="$(cd -- "$(dirname -- "$1")" && pwd -P)" || return 1
    base="$(basename -- "$1")"
    printf '%s/%s\n' "${dir%/}" "${base}"
}

# Is a TCP port already listening? ss on Linux, lsof on macOS. If neither exists
# we report "free" and let qemu fail with a bind error, which is still clearer
# than refusing to start.
port_in_use() {
    local port="$1"
    if check_command ss; then
        ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .
        return $?
    fi
    if check_command lsof; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN > /dev/null 2>&1
        return $?
    fi
    return 1
}

show_usage() {
    cat << EOF
Usage: $0 [options] [-- extra qemu args]

Launch a WendyOS VM image under QEMU/KVM with UEFI firmware.

Options:
    -n, --name NAME      Instance name (default: default). Each instance gets its
                         own disk overlay and UEFI variables, so several can run
                         at once from one shared base image.
    -b, --build-dir DIR  Build directory (default: build)
    -m, --machine NAME   Yocto MACHINE: vm-x86-64-wendyos (default) or
                         vm-arm64-wendyos
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
        --bios FILE      Use a single-file firmware via -bios instead of the
                         autodetected CODE/VARS pflash pair. Mainly for booting
                         a firmware this script does not know about; the
                         normal path is autodetection.
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
    $0 -m vm-arm64-wendyos              # the arm64 image (TCG on an x86_64 host)

Shutting down cleanly:
    Run 'poweroff' in the guest, or press Ctrl-A then C for the QEMU monitor and
    type 'system_powerdown'. Do NOT use Ctrl-A X — that kills the VM instantly,
    which can leave an in-progress A/B update half-applied.

Notes:
    - The guest reaches host services at 10.0.2.2 (QEMU user networking). That
      address is virtual and never appears in 'ip addr' on the host.
    - Instance state lives in <workspace>/vm/<machine>/<name>/, so the same
      instance name can be used for each machine without collision.
    - Running a guest of a different architecture than the host uses TCG
      emulation. It works, but expect a boot measured in minutes.
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

    # `ls -1t` rather than `find -printf`: the latter is GNU-only.
    local -a candidates=()
    local f
    for f in "${deploy_dir}"/*.wic; do
        if [[ -f "${f}" && ! -L "${f}" ]]; then
            candidates+=("${f}")
        fi
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        error "No .wic image in ${deploy_dir}"
        return 1
    fi

    newest="$(ls -1t "${candidates[@]}" | head -1)"
    abs_path "${newest}"
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
    error "No UEFI firmware found for ${GUEST_ARCH}."
    error "  ${FIRMWARE_HINT}"
    error "Looked for: ${FIRMWARE_PAIRS[*]}"
    error "Or pass --bios <file> to point at a single-file firmware directly."
    return 1
}

# First free TCP port at or above $1, so two instances never collide.
find_free_port() {
    local port="$1"
    local limit=$((port + 100))
    while [[ "${port}" -lt "${limit}" ]]; do
        if ! port_in_use "${port}"; then
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
            -n|--name)
                NAME="$2"
                shift 2
                ;;
            -b|--build-dir)
                BUILD_DIR="$2"
                shift 2
                ;;
            -m|--machine)
                MACHINE="$2"
                shift 2
                ;;
            --memory)
                MEMORY="$2"
                shift 2
                ;;
            --cpus)
                CPUS="$2"
                shift 2
                ;;
            --disk-size)
                DISK_GROW="$2"
                shift 2
                ;;
            --ssh-port)
                SSH_PORT="$2"
                shift 2
                ;;
            --bios)
                BIOS="$2"
                shift 2
                ;;
            --recreate)
                RECREATE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            --)
                shift
                EXTRA_ARGS=("$@")
                break
                ;;
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

    # Resolve the arch table first -- everything below depends on it.
    select_arch || exit 1

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    workspace_dir="$(cd "${script_dir}/../.." && pwd)"
    deploy_dir="${workspace_dir}/${BUILD_DIR}/tmp/deploy/images/${MACHINE}"

    for tool in "${QEMU_BIN}" qemu-img; do
        check_command "${tool}" || { error "Required tool not found: ${tool}"; exit 1; }
    done

    base_image="$(find_base_image "${deploy_dir}")" || exit 1

    if [[ -n "${BIOS}" ]]; then
        # Single-file firmware (-bios): no writable variable store, so UEFI
        # variables do not persist across boots. Fine for our chain, which boots
        # the removable-media path EFI/BOOT/boot{x64,aa64}.efi and never relies on
        # NVRAM boot entries.
        [[ -r "${BIOS}" ]] || { error "Firmware not readable: ${BIOS}"; exit 1; }
        fw_code=""
        fw_vars=""
    else
        fw_pair="$(find_firmware)" || exit 1
        fw_code="${fw_pair%%:*}"
        fw_vars="${fw_pair##*:}"
    fi

    # Namespaced by MACHINE, not just by name. An overlay is one machine's disk:
    # its backing file, partition layout and guest architecture all belong to that
    # machine, so "default" for vm-arm64-wendyos and "default" for
    # vm-x86-64-wendyos must be different instances. Without this they collide and
    # the second machine silently inherits the first machine's disk.
    state_dir="${workspace_dir}/vm/${MACHINE}/${NAME}"
    overlay="${state_dir}/disk.qcow2"
    nvram="${state_dir}/efi-vars.fd"

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
        if [[ -z "${BIOS}" ]]; then
            execute "cp '${fw_vars}' '${nvram}'"
        fi
    else
        # Warn if the base moved on: a rebuild writes a new timestamped .wic, and
        # this overlay stays bound to the one it was created from.
        local bound
        bound="$(qemu-img info --output=json "${overlay}" 2>/dev/null \
            | sed -n 's/.*"full-backing-filename": *"\([^"]*\)".*/\1/p' | head -1)"
        if [[ -n "${bound}" && ! -e "${bound}" ]]; then
            # Fatal, not a warning: qemu cannot open the overlay at all, and the
            # only recovery is to rebuild the instance.
            error "Instance ${NAME} is bound to an image that no longer exists:"
            error "  ${bound}"
            error "Rebuild it against the current image with --recreate."
            exit 1
        fi

        if [[ -n "${bound}" && "${bound}" != "${base_image}" ]]; then
            warning "Instance ${NAME} is bound to an older image:"
            warning "  ${bound}"
            warning "Newest build is:"
            warning "  ${base_image}"
            warning "Use --recreate to move this instance to the new image."
        fi

        if [[ -z "${BIOS}" && ! -e "${nvram}" ]]; then
            error "Instance ${NAME} has no UEFI variable store at ${nvram}."
            error "Use --recreate to rebuild this instance."
            exit 1
        fi
    fi

    # Hardware acceleration needs the guest and host to share an architecture --
    # a hypervisor virtualizes, it does not translate. An arm64 guest on an x86_64
    # host is TCG regardless of what /dev/kvm says, which is exactly the case that
    # lets a Linux x86_64 workstation boot the arm64 image at all.
    local host_os host_arch
    host_os="$(uname -s)"
    host_arch="$(norm_arch "$(uname -m)")"

    accel="tcg"
    cpu_model="${CPU_TCG}"

    if [[ "${host_arch}" == "${GUEST_ARCH}" ]]; then
        case "${host_os}" in
            Linux)
                if [[ -w /dev/kvm ]]; then
                    accel="kvm"
                else
                    warning "/dev/kvm not readable — falling back to software emulation (slow)."
                    warning "Add yourself to the 'kvm' group to fix this."
                fi
                ;;
            Darwin)
                # Hypervisor.framework. UNVERIFIED: not run on a Mac. QEMU builds
                # for macOS enable hvf by default and Homebrew's is signed for the
                # hypervisor entitlement, so this is expected to work; if it does
                # not, qemu says "invalid accelerator hvf" and --dry-run shows the
                # exact command to adjust.
                accel="hvf"
                ;;
            *)
                warning "Unrecognised host OS '${host_os}': using software emulation."
                ;;
        esac
    else
        warning "${GUEST_ARCH} guest on a ${host_arch} host: TCG emulation."
        warning "This works and exercises the real boot chain, but expect the"
        warning "boot to take minutes rather than seconds."
    fi

    if [[ "${accel}" != "tcg" ]]; then
        cpu_model="${CPU_KVM}"
        if [[ "${GUEST_ARCH}" == "aarch64" ]]; then
            # An accelerated arm64 guest needs a GICv3; virt's GICv2 default caps
            # vCPUs at 8. genericarm64's own QB_CPU_KVM sets the same.
            QEMU_MACHINE="${QEMU_MACHINE},gic-version=3"
        fi
    fi
    debug "host=${host_os}/${host_arch} guest=${GUEST_ARCH} accel=${accel} cpu=${cpu_model}"

    if [[ -z "${SSH_PORT}" ]]; then
        SSH_PORT="$(find_free_port 2222)" || exit 1
    fi

    info "SSH:       ssh -p ${SSH_PORT} wendy@localhost"
    info ""
    success "Starting ${NAME} (${CPUS} vCPU, ${MEMORY} MB, ${accel})."
    info "Exit cleanly with 'poweroff' in the guest, or Ctrl-A C then 'system_powerdown'."
    info ""

    local -a fw_args=()
    if [[ -n "${BIOS}" ]]; then
        fw_args=(-bios "${BIOS}")
    else
        fw_args=(
            -drive "if=pflash,format=raw,unit=0,readonly=on,file=${fw_code}"
            -drive "if=pflash,format=raw,unit=1,file=${nvram}"
        )
    fi

    local -a qemu_cmd=(
        "${QEMU_BIN}"
        -machine "${QEMU_MACHINE},accel=${accel}"
        -cpu "${cpu_model}"
        -smp "${CPUS}"
        -m "${MEMORY}"
        "${fw_args[@]}"
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
