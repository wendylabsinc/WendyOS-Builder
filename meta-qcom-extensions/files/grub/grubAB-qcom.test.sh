#!/usr/bin/env bash
#
# Static checks on the Dragonwing A/B GRUB config.
#
# The config runs before any userspace exists, so a mistake in it is only
# observable as a device that will not boot -- and its two failure paths (trial
# fall-back, kernel-load failure) are exactly the ones that are hardest to
# exercise by hand. These assertions are cheap and catch the drift that review
# tends to miss.
#
# Run: bash meta-qcom-extensions/files/grub/grubAB-qcom.test.sh

set -uo pipefail

CFG="$(dirname "$0")/grubAB-qcom.cfg"
fails=0

check() {
    if [ "$1" = "0" ]; then
        printf '  ok    %s\n' "$2"
    else
        printf '  FAIL  %s\n' "$2"
        fails=$((fails + 1))
    fi
}

[ -f "$CFG" ] || { printf 'grubAB-qcom.cfg not found at %s\n' "$CFG" >&2; exit 1; }
printf 'Checking %s\n' "$CFG"

# Strip comments once: prose mentions variable names and partition numbers, and
# a comment must never satisfy (or break) an assertion.
BODY="$(grep -vE '^[[:space:]]*#' "$CFG")"

# --- 1. every persisted variable has a first-boot default -------------------
# A fresh device's grubenv is an empty block: every variable reads back as "".
# The config must therefore default each one it relies on, or the very first
# boot evaluates an empty slot number. Deriving the list from save_env means a
# newly persisted variable cannot be added without also being guarded.
saved="$(printf '%s\n' "$BODY" | grep -oE '^[[:space:]]*save_env .*' \
    | sed 's/^[[:space:]]*save_env //' | tr ' ' '\n' | sort -u | grep -v '^$')"
[ -n "$saved" ] || { printf '  FAIL  no save_env statements found (config gutted?)\n'; fails=$((fails + 1)); }

for v in $saved; do
    printf '%s\n' "$BODY" | grep -qF "if [ -z \"\${$v}\" ]"
    check $? "persisted variable '$v' has a -z first-boot default"
done

# --- 2. the connector contract is intact ------------------------------------
# These three names are the shared contract with the wendyos-update grubenv
# connector (internal/connector/grubenv/grubenv.go) and with the U-Boot boards'
# boot script. Renaming one here silently breaks OTA on this board only.
for v in wendyos_boot_slot wendyos_upgrade_available bootcount; do
    printf '%s\n' "$BODY" | grep -qF "if [ -z \"\${$v}\" ]"
    check $? "contract variable '$v' is defaulted"
done

printf '%s\n' "$BODY" | grep -qE '^[[:space:]]*load_env'
check $? "load_env is called (otherwise persisted state is never read)"

# --- 3. slot -> partition mapping matches partitions.conf -------------------
# GRUB addresses the slots by NUMBER because an OTA raw-write clobbers a slot's
# filesystem label. wendyos-grub-ab substitutes the numbers from the machine's
# partitions.conf, so the config must never carry a literal one.
n_a=$(printf '%s\n' "$BODY" | grep -cF 'gpt@ROOTFSA_PART@')
n_b=$(printf '%s\n' "$BODY" | grep -cF 'gpt@ROOTFSB_PART@')
rc=0
test "$n_a" -ge 2 && test "$n_b" -ge 2 || rc=1
check "$rc" "slots addressed through the substituted partition numbers (A=$n_a B=$n_b)"

! printf '%s\n' "$BODY" | grep -qE 'gpt[0-9]'
check $? "no hardcoded gptN partition number"

# Every layout this config boots (this layer's and each board layer's) must end
# in WendyOS's own partitions, data last so the flash can grow it over the disk.
ROOT="$(dirname "$0")/../../.."
found=0
for PCONF in "$ROOT"/meta-*-extensions/recipes-bsp/partition/files/partitions.conf; do
    [ -f "$PCONF" ] || continue
    found=1
    tail5="$(grep -oE '^--partition .*--name=[a-zA-Z_]+' "$PCONF" \
        | sed 's/.*--name=//' | tail -n 5 | tr '\n' ' ')"
    rc=0
    test "$tail5" = "efi config rootfsA rootfsB data " || rc=1
    check "$rc" "${PCONF#"$ROOT"/} ends in 'efi config rootfsA rootfsB data' (got: $tail5)"
done
[ "$found" = "1" ] || printf '  skip  no partitions.conf found\n'

# --- 4. no x86 leftovers ----------------------------------------------------
# This config is a port of meta-x86-extensions' grubAB.cfg. Both x86-isms boot
# nothing on aarch64: bzImage does not exist, and ttyS0 is not this SoC's UART.
! printf '%s\n' "$BODY" | grep -qF 'bzImage'
check $? "no bzImage reference (aarch64 kernel is 'Image')"

printf '%s\n' "$BODY" | grep -qF '/boot/Image'
check $? "loads /boot/Image from inside the rootfs slot"

! printf '%s\n' "$BODY" | grep -qF 'ttyS0'
check $? "no ttyS0 reference (the Dragonwing console is ttyMSM0)"

printf '%s\n' "$BODY" | grep -qF 'ttyMSM0'
check $? "console is ttyMSM0"

# --- 4b. the kernel must be given OUR device tree ---------------------------
# With no `devicetree` command the kernel inherits the DTB UEFI installed from the
# dtb_a partition -- the vendor tree for Qualcomm Linux's 6.6 kernel. Against this
# mainline 7.2 kernel it lacks the UFS regulator bindings, so ufshcd-qcom never
# probes, no disk appears, and rootwait hangs silently. Cost us a flash cycle to
# find on hardware, so assert it rather than trusting review.
printf '%s\n' "$BODY" | grep -qE '(^|[[:space:]])devicetree[[:space:]]'
check $? "config loads a device tree with the 'devicetree' command"

# One devicetree per linux. A whole-file count, not per-menuentry pairing, but
# enough to catch a dropped devicetree line.
n_linux=$(printf '%s\n' "$BODY" | grep -cE '(^|[[:space:]])linux[[:space:]]')
n_dtb=$(printf '%s\n' "$BODY" | grep -cE '(^|[[:space:]])devicetree[[:space:]]')
rc=0
test "$n_dtb" -ge "$n_linux" || rc=1
check "$rc" "a 'devicetree' for every 'linux' (linux=$n_linux devicetree=$n_dtb)"

# A failed devicetree load must not fall through to `linux`: the kernel would boot
# the vendor DTB, ufshcd-qcom would never probe, and rootwait would hang forever.
printf '%s\n' "$BODY" | awk '/if ! devicetree/,/^[[:space:]]*fi/' \
    | grep -q 'wendyos_fall_back_and_reboot'
check $? "a failed 'devicetree' load calls the slot fallback"

# ...and the fallback must SWITCH slots, not just reboot. The trial block only
# counts while an update is armed, so a bare reboot on a committed slot would
# retry the same broken slot forever and never reach the known-good one.
FALLBACK="$(printf '%s\n' "$BODY" | awk '/^function wendyos_fall_back_and_reboot/,/^}/')"
printf '%s\n' "$FALLBACK" | grep -q 'set wendyos_boot_slot=1' \
    && printf '%s\n' "$FALLBACK" | grep -q 'set wendyos_boot_slot=0' \
    && printf '%s\n' "$FALLBACK" | grep -q 'save_env wendyos_boot_slot' \
    && printf '%s\n' "$FALLBACK" | grep -q 'set wendyos_upgrade_available=0'
check $? "the fallback flips the slot, persists it, and abandons the trial"

# The DTB name must come from WENDYOS_QCOM_DTB, not a second hardcoded copy that
# can drift from the machine's KERNEL_DEVICETREE.
printf '%s\n' "$BODY" | grep -q 'wendyos_dtb=@WENDYOS_QCOM_DTB@'
check $? "the DTB filename is substituted from WENDYOS_QCOM_DTB"
! printf '%s\n' "$BODY" | grep -qE 'wendyos_dtb=[a-z0-9-]+\.dtb'
check $? "no hardcoded .dtb filename in the config"

# The DTB must come from the SLOT, not the shared ESP: dtb+kernel+rootfs have to
# travel together or an OTA can boot a new rootfs against a stale device tree.
! printf '%s\n' "$BODY" | grep -E '(^|[[:space:]])devicetree[[:space:]]' | grep -qvE '\$\{slotdev\}|\(\$\{d\},gpt@ROOTFS[AB]_PART@\)'
check $? "device tree is loaded from the rootfs slot, not the ESP"

# The machine's kernel arguments must reach every boot path, manual ones included.
n_args=$(printf '%s\n' "$BODY" | grep -E '(^|[[:space:]])linux[[:space:]]' | grep -cF '@WENDYOS_QCOM_KERNEL_ARGS@')
rc=0
test "$n_args" -eq "$n_linux" || rc=1
check "$rc" "every 'linux' line carries WENDYOS_QCOM_KERNEL_ARGS (linux=$n_linux with=$n_args)"

# --- 5. commands used must be built into the GRUB image ---------------------
# grub-mkimage bakes a fixed module set into bootaa64.efi and the ESP carries no
# module directory, so a command that is not built in is simply absent at boot.
# This was found on hardware: 'echo' was missing and every message silently
# failed. Keep this list in step with GRUB_BUILDIN in
# meta-qcom-extensions/recipes-bsp/grub/grub-efi_%.bbappend plus oe-core's
# default set.
BBAPPEND="$(dirname "$0")/../../recipes-bsp/grub/grub-efi_%.bbappend"
OECORE_DEFAULT="boot linux ext2 fat serial part_msdos part_gpt normal efi_gop iso9660 configfile search loadenv test"
if [ -f "$BBAPPEND" ]; then
    added="$(grep -oE 'GRUB_BUILDIN:append *= *"[^"]*"' "$BBAPPEND" \
        | sed 's/.*= *"//; s/"$//')"
    available=" $OECORE_DEFAULT $added "
    # loadenv provides load_env/save_env; test provides '['.
    for cmd in echo regexp reboot sleep linux devicetree; do
        printf '%s\n' "$BODY" | grep -qE "(^|[[:space:]])${cmd}([[:space:]]|$)" || continue
        mod="$cmd"
        # `devicetree` is provided by the fdt module; loadenv provides load_env.
        [ "$cmd" = "devicetree" ] && mod="fdt"
        printf '%s' "$available" | grep -qE "[[:space:]]${mod}[[:space:]]"
        check $? "command '$cmd' (module '$mod') is built into GRUB"
    done
    printf '%s\n' "$BODY" | grep -qE '(^|[[:space:]])(load_env|save_env)([[:space:]]|$)' && {
        printf '%s' "$available" | grep -qE '[[:space:]]loadenv[[:space:]]'
        check $? "loadenv module present for load_env/save_env"
    }
else
    printf '  skip  grub-efi bbappend not found\n'
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
    printf 'All checks passed.\n'
    exit 0
fi
printf '%d check(s) FAILED.\n' "$fails"
exit 1
