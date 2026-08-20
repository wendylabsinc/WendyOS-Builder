#!/usr/bin/env bash
#
# check-repo-pins.sh -- assert that boards sharing a layer tree agree on the
# revision of every layer they share.
#
# WHY THIS EXISTS
#
# Upstream layer clones live in repos/${WENDYOS_LAYER_TREE}/, one directory per
# layer, shared by every board on that series. A directory can hold exactly one
# revision. So if two boards both put a layer in BBLAYERS but pin it to different
# SRCREVs, that layer cannot be correct for both at once -- whichever board
# bootstrapped last wins, and the other would build against the wrong source.
#
# Pins are declared in two places: scripts/upstream-repos.env holds the shared
# blacksail set, and conf/template/boards/<board>/repos.overrides may override
# it. Nothing in that structure enforces agreement. The blacksail set used to be
# restated in ten board files, and on 2026-08-04 a meta-tegra re-pin was applied
# to one Jetson board and missed four others, all of which would have failed the
# same way. Those restatements are gone, but an override can still be added to a
# single board. This check is what catches that class.
#
# It compares pins ONLY between boards that actually layer the repo, because a
# board that never puts a layer in BBLAYERS cannot be affected by its revision.
# That is why e.g. meta-tegra legitimately resolves differently on x86 (which
# does not layer it) than on Thor (which does).
#
# Exit status: 0 = no conflicts, 1 = at least one conflict (usable in CI).
#
# Usage:
#   scripts/check-repo-pins.sh [--verbose]
#
#   --verbose   also print the full resolved (tree, layer, pin) -> boards table

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/conf/template"

VERBOSE=0
for arg in "$@"
do
    case "${arg}" in
        --verbose|-v)
            VERBOSE=1
            ;;
        --help|-h)
            sed -n '3,32p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            printf "Unknown argument: %s\n" "${arg}" >&2
            exit 1
            ;;
    esac
done

# shellcheck source=scripts/repo-pins.lib.sh
source "${SCRIPT_DIR}/repo-pins.lib.sh"

# Every SRCREV_* the repos list can use, paired with the folder it clones into.
# Keep in step with the repos[] array in bootstrap.sh.
PIN_VARS="
bitbake:SRCREV_BITBAKE
openembedded-core:SRCREV_OECORE
meta-yocto:SRCREV_METAYOCTO
meta-openembedded:SRCREV_OE
meta-tegra:SRCREV_TEGRA
meta-tegra-community:SRCREV_TEGRA_COMM
meta-virtualization:SRCREV_VIRT
meta-raspberrypi:SRCREV_RPI
meta-security:SRCREV_SECURITY
"

MATRIX="$(mktemp)"
trap 'rm -f "${MATRIX}"' EXIT

for board_dir in "${TEMPLATE_DIR}"/boards/*/
do
    [[ -d "${board_dir}" ]] || continue
    board="$(basename "${board_dir}")"

    required="$(required_repo_folders "${board_dir}" "${TEMPLATE_DIR}")"

    # Resolve pins exactly as bootstrap does: defaults first, board file second,
    # plain assignment so the board wins. Subshell keeps boards independent.
    (
        set +u
        # shellcheck source=scripts/upstream-repos.env
        source "${REPO_ROOT}/scripts/upstream-repos.env"
        if [[ -f "${board_dir}/repos.overrides" ]]
        then
            # shellcheck source=/dev/null
            source "${board_dir}/repos.overrides"
        fi

        tree="${WENDYOS_LAYER_TREE}"

        while read -r entry
        do
            [[ -n "${entry}" ]] || continue
            folder="${entry%%:*}"
            var="${entry##*:}"

            # Only layers this board actually puts in BBLAYERS can conflict.
            printf '%s\n' "${required}" | grep -qxF "${folder}" || continue

            printf '%s|%s|%s|%s\n' "${tree}" "${folder}" "${!var:-<unset>}" "${board}" \
                >> "${MATRIX}"
        done < <(printf '%s\n' "${PIN_VARS}")

        # REPOS_EXTRA clones are board-declared rather than derived from
        # bblayers, so they are not in PIN_VARS and are exempt from the layer
        # check -- but they land in the same shared tree, so two boards naming
        # the same folder must still agree on its revision.
        if [[ -n "${REPOS_EXTRA+x}" ]]
        then
            for entry in "${REPOS_EXTRA[@]}"
            do
                folder="$(echo "${entry}" | cut -d'|' -f 3)"
                [[ -n "${folder}" ]] || folder="$(basename "$(echo "${entry}" | cut -d'|' -f 2)" .git)"
                printf '%s|%s|%s|%s\n' \
                    "${tree}" "${folder}" "$(echo "${entry}" | cut -d'|' -f 4)" "${board}" \
                    >> "${MATRIX}"
            done
        fi
    )
done

if [[ "${VERBOSE}" -eq 1 ]]
then
    printf "=== resolved pins, per tree and layer (only boards that layer it) ===\n"
    sort -t'|' -k1,1 -k2,2 -k3,3 "${MATRIX}" \
        | awk -F'|' '{ key=$1" "$2" "substr($3,1,12); boards[key]=boards[key]" "$4 }
                     END { for (k in boards) print "  "k":"boards[k] }' \
        | sort
    printf "\n"
fi

# A conflict is a (tree, layer) with more than one distinct pin among the boards
# that layer it.
CONFLICTS="$(sort -u "${MATRIX}" \
    | awk -F'|' '{ pins[$1"|"$2][$3]=1; who[$1"|"$2"|"$3]=who[$1"|"$2"|"$3]" "$4 }
                 END {
                     for (k in pins) {
                         n=0
                         for (p in pins[k]) n++
                         if (n > 1) {
                             print "CONFLICT: tree/layer " k
                             for (p in pins[k]) print "    " substr(p,1,12) " <-" who[k"|"p]
                         }
                     }
                 }')"

if [[ -n "${CONFLICTS}" ]]
then
    printf "%s\n\n" "${CONFLICTS}" >&2
    printf "Each of those layers is one directory under repos/<tree>/, so it can hold\n" >&2
    printf "only one of those revisions. Boards listed above disagree about which.\n" >&2
    exit 1
fi

printf "OK: every layer has a single pin among the boards that use it.\n"
printf "    %s board(s), %s (tree, layer) pairs checked.\n" \
    "$(find "${TEMPLATE_DIR}/boards" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
    "$(cut -d'|' -f1,2 "${MATRIX}" | sort -u | wc -l)"
