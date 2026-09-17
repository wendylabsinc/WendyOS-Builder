#!/usr/bin/env bash
#
# Static checks on the Dragonwing NPU stack.
#
# Two failure modes here are invisible to a build: the DSP firmware refuses a userspace
# it does not authorise, and an unsatisfiable RRECOMMENDS drops a package silently.
#
# Run: bash scripts/qcom-npu.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG="$ROOT/meta-qcom-extensions/recipes-core/packagegroups/packagegroup-wendyos-qcom.bb"
BBA="$ROOT/meta-qcom-extensions/recipes-bsp/hexagon-dsp-binaries/hexagon-dsp-binaries_%.bbappend"
DISTRO="$ROOT/conf/distro/include/qcom-distro.inc"
REPOSENV="$ROOT/scripts/upstream-repos.env"
OECORE="$ROOT/../repos/blacksail/openembedded-core"
fails=0

check() {
    if [ "$1" = "0" ]; then
        printf '  ok    %s\n' "$2"
    else
        printf '  FAIL  %s\n' "$2"
        fails=$((fails + 1))
    fi
}

for f in "$PG" "$BBA" "$DISTRO" "$REPOSENV"; do
    [ -f "$f" ] || { printf 'missing input: %s\n' "$f" >&2; exit 1; }
done
printf 'Checking the Dragonwing NPU stack\n'

# A comment must never satisfy an assertion.
strip() { grep -vE '^[[:space:]]*#' "$1"; }


# Every Dragonwing machine must be covered; a renamed conf would otherwise drop
# out of the glob and leave the loop asserting nothing.
machines=("$ROOT"/conf/machine/iq-*-evk-wendyos.conf)
if [ "${#machines[@]}" -lt 2 ] || [ ! -f "${machines[0]}" ]; then
    printf 'expected at least 2 Dragonwing machine confs, found: %s\n' \
        "${machines[*]}" >&2
    exit 1
fi

for MACH in "${machines[@]}"; do
    mname="$(basename "$MACH" .conf)"
    mbody="$(strip "$MACH")"
    board="$(getv WENDYOS_QCOM_NPU_BOARD "$mbody")"
    arch="$(getv WENDYOS_QCOM_NPU_DSP_ARCH "$mbody")"
    soc="$(getv WENDYOS_QCOM_NPU_SOC "$mbody")"

    if [ -n "$board" ] && [ -n "$arch" ] && [ -n "$soc" ]; then rc=0; else rc=1; fi
    check "$rc" "$mname declares its DSP board, arch and SoC"

    # An unexpanded variable becomes a package name that does not exist, which
    # do_rootfs reports far from its cause.
    expanded="$(printf '%s\n' "$TEMPLATE" \
        | sed -e "s/\${WENDYOS_QCOM_NPU_BOARD}/$board/g" \
              -e "s/\${WENDYOS_QCOM_NPU_DSP_ARCH}/$arch/g")"
    # shellcheck disable=SC2016  # the literal '${' is what is being searched for
    printf '%s\n' "$expanded" | grep -qF '${'
    check $((1 - $?)) "$mname expands every variable the template uses"

    # Structure alone is not enough: a swapped qualcomm-/qcom- prefix or a
    # renamed -gdsp suffix passes every check above and surfaces only as an
    # unresolvable package at do_rootfs.
    want="$(printf '%s\n' \
        "hexagon-dsp-binaries-qualcomm-$board-config" \
        "hexagon-dsp-binaries-qcom-$board-adsp" \
        "hexagon-dsp-binaries-qcom-$board-cdsp" \
        "hexagon-dsp-binaries-qcom-$board-gdsp" \
        "qairt-sdk" \
        "qairt-sdk-hexagon-$arch" \
        "fastrpc-tests" | sort)"
    if [ "$(printf '%s\n' "$expanded" | sort)" = "$want" ]; then rc=0; else rc=1; fi
    check "$rc" "$mname resolves to exactly the expected DSP package names"

    # A SoC absent from the retarget list ships a userspace the firmware refuses,
    # at runtime, with a green build.
    if [ -n "$soc" ] && printf '%s\n' "$SOCS" | tr ' ' '\n' | grep -qx "$soc"; then
        rc=0
    else
        rc=1
    fi
    check "$rc" "$mname's SoC (${soc:-unset}) is in WENDYOS_QCOM_DSP_SOCS"

    npu="$(getv WENDYOS_QCOM_NPU "$mbody")"
    if [ "$npu" = "1" ]; then rc=0; else rc=1; fi
    check "$rc" "$mname has the NPU on by default"
done

# --- 2. hard dependencies, not recommendations ------------------------------
# Joined into one logical line first: the recipe's own idiom is a backslash-continued
# list, so a line-at-a-time match cannot see a multi-line RRECOMMENDS.
printf '%s\n' "$PGBODY" | grep -qE 'RDEPENDS:\$\{PN\}[[:space:]]*\+=.*NPU_INSTALL'
check $? "the stack is installed via RDEPENDS"
# Comments are stripped, so any occurrence left is a real declaration.
printf '%s\n' "$PGBODY" | grep -qF 'RRECOMMENDS'
check $((1 - $?)) "and the recipe declares no RRECOMMENDS at all"

# --- 3. it is in the image, not an extension --------------------------------
printf '%s\n' "$PGBODY" | grep -qF "d.getVar('WENDYOS_QCOM_NPU') == '1'"
check $? "the install list is still gated on the knob"

# --- 4. the firmware pairing ------------------------------------------------
# The pin must name the version oe-core ships, or do_rootfs cannot resolve it.
printf '%s\n' "$DISTROBODY" | grep -qE '^WENDYOS_QCOM_DSP_BUILD[[:space:]]*\??='
check $? "the DSP build is pinned distro-wide"
FWPV="$(printf '%s\n' "$DISTROBODY" | sed -nE 's/^WENDYOS_QCOM_DSP_FW_PV[[:space:]]*\??=[[:space:]]*"([^"]+)".*/\1/p')"
if [ -n "$FWPV" ]; then check 0 "the firmware version it is matched to is pinned"
else check 1 "WENDYOS_QCOM_DSP_FW_PV is not pinned"; fi

# An oe-core bump can move linux-firmware, and with it which binaries the signed firmware
# admits. Comparing the two revisions needs no checkout, so unlike the check below it also
# runs in CI.
pin() { sed -nE "s/^$1=\"([^\"]+)\".*/\1/p" "$REPOSENV"; }
OEREV="$(pin SRCREV_OECORE)"
OEVERIFIED="$(pin SRCREV_OECORE_DSP_VERIFIED)"
if [ -n "$OEREV" ] && [ "$OEREV" = "$OEVERIFIED" ]; then
    check 0 "the DSP pairing was verified against the pinned oe-core"
else
    check 1 "oe-core is at ${OEREV:-unset}, pairing verified at ${OEVERIFIED:-unset}; \
re-check the pairing and update SRCREV_OECORE_DSP_VERIFIED"
fi

if [ -d "$OECORE" ]; then
    OEPV="$(find "$OECORE/meta/recipes-kernel/linux-firmware" -maxdepth 1 \
        -name 'linux-firmware_*.bb' -printf '%f\n' 2>/dev/null \
        | sed -nE 's/^linux-firmware_(.+)\.bb$/\1/p' | head -1)"
    if [ -n "$OEPV" ] && [ "$FWPV" = "$OEPV" ]; then
        check 0 "the pin ($FWPV) matches oe-core's linux-firmware ($OEPV)"
    else
        check 1 "the pin ($FWPV) does not match oe-core's linux-firmware (${OEPV:-unknown})"
    fi
else
    printf '  skip  oe-core not checked out; the revision check above stands in\n'
fi

# --- 5. the retarget cannot silently no-op ----------------------------------
# A no-op retarget ships a userspace the firmware refuses, with a green build.
printf '%s\n' "$BBABODY" | grep -qF 'bbfatal'
check $? "the bbappend asserts the retarget substituted"
printf '%s\n' "$BBABODY" | grep -qE "do_install:(prepend|append)"
check $? "and hooks upstream's do_install rather than replacing it"

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'all checks passed' || echo "$fails check(s) failed")"
exit $((fails > 0))
