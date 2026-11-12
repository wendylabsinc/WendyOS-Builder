#!/usr/bin/env bash
#
# Static checks on the Dragonwing NPU stack.
#
# One failure mode here is invisible to a build: an unsatisfiable RRECOMMENDS drops a
# package silently.
#
# Run: bash scripts/qcom-npu.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG="$ROOT/meta-qcom-extensions/recipes-core/packagegroups/packagegroup-wendyos-qcom.bb"
fails=0

check() {
    if [ "$1" = "0" ]; then
        printf '  ok    %s\n' "$2"
    else
        printf '  FAIL  %s\n' "$2"
        fails=$((fails + 1))
    fi
}

if [ ! -f "$PG" ]; then
    printf 'missing input: %s\n' "$PG" >&2
    exit 1
fi

printf 'Checking the Dragonwing NPU stack\n'

# A comment must never satisfy an assertion.
strip() { grep -vE '^[[:space:]]*#' "$1"; }

# Inline our machine includes where the require sits, so assignments read in the
# order BitBake applies them.
expand_conf() {
    local line inc
    while IFS= read -r line; do
        case "$line" in
        "require conf/machine/include/"*)
            inc="$ROOT/${line#require }"
            if [ -f "$inc" ]; then expand_conf "$inc"; else printf '%s\n' "$line"; fi
            ;;
        *) printf '%s\n' "$line" ;;
        esac
    done <"$1"
}
PGBODY="$(strip "$PG")"

# --- 1. the stack is complete, and expands for every Dragonwing machine ------
# Read the template from the recipe: a restated list cannot notice a deletion.
TEMPLATE="$(printf '%s\n' "$PGBODY" \
    | sed -n '/^WENDYOS_QCOM_NPU_INSTALL/,/^[[:space:]]*"/p' \
    | awk '$1 ~ /^[a-z0-9$]/ { print $1 }')"
n=$(printf '%s\n' "$TEMPLATE" | grep -c .)
if [ "$n" -ge 7 ]; then check 0 "the install template parses ($n packages)"
else check 1 "the install template parses (got $n packages, expected at least 7)"; fi

# The template must be board-agnostic: a literal board name here would silently
# install the wrong DSP userspace on the other machine.
printf '%s\n' "$TEMPLATE" | grep -qE 'iq[0-9]+-evk|hexagon-v[0-9]+'
check $((1 - $?)) "the template names no board or Hexagon version literally"

# '?=' is a no-op once the variable has a value, so a last-match read would
# report a weak default that an assignment above the require already overrode.
getv() {
    printf '%s\n' "$2" | awk -v v="$1" '
        $1 == v && ($2 == "=" || $2 == "?=") {
            if (match($0, /"[^"]*"/)) {
                val = substr($0, RSTART + 1, RLENGTH - 2)
                if ($2 == "=" || !set) { out = val; set = 1 }
            }
        }
        END { print out }'
}

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
    mbody="$(expand_conf "$MACH" | grep -vE '^[[:space:]]*#')"
    board="$(getv WENDYOS_QCOM_NPU_BOARD "$mbody")"
    arch="$(getv WENDYOS_QCOM_NPU_DSP_ARCH "$mbody")"

    if [ -n "$board" ] && [ -n "$arch" ]; then
        rc=0
    else
        rc=1
    fi
    check "$rc" "$mname declares its DSP board and arch"

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

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'all checks passed' || echo "$fails check(s) failed")"
exit $((fails > 0))
