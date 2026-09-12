# Shared helpers for reasoning about upstream layer clones and their pins.
#
# Sourced by bootstrap.sh (which acts on the answer) and by
# scripts/check-repo-pins.sh (which lints it). Both must agree on which layers a
# board needs, so the derivation lives here once rather than in each caller --
# two copies of this logic would recreate the drift problem the lint exists to
# catch.
#
# Not executable, no side effects: defines functions only.

###
# Folder names under repos/${WENDYOS_LAYER_TREE}/ that a board actually needs,
# one per line.
#
#   required_repo_folders <board_dir> <template_dir>
#
# Every board's bblayers.conf requires a few shared fragments from
# <template_dir>/include/bblayers/, and those name each upstream layer by path:
# ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/<folder>/<sublayer>. That is the list
# BitBake itself parses, so deriving from it cannot disagree with what the build
# needs -- unlike a per-board list, which would restate knowledge that already
# lives in bblayers and could drift out of step with it.
#
# bitbake is always included: it is the build tool, not a layer, so it never
# appears in BBLAYERS. openembedded-core is always needed too (oe-init-build-env
# lives there), but it falls out of the derivation anyway because every board
# pulls bblayers/oe-common.inc.
function required_repo_folders() {
    local board_dir="${1}"
    local template_dir="${2}"
    local files=("${board_dir}/bblayers.conf")
    local inc

    # One level is enough: the bblayers fragments do not require each other.
    while read -r inc
    do
        [[ -n "${inc}" ]] || continue
        files+=("${template_dir}/include/${inc}")
    done < <(grep -ohE 'bblayers/[a-zA-Z0-9._-]+\.inc' "${board_dir}/bblayers.conf" | sort -u)

    {
        printf "bitbake\n"
        # Strip comments first: several of these files mention repos/<tree>/
        # paths in prose, and a comment must not invent a requirement.
        # ${WENDYOS_LAYER_TREE} is still unexpanded here, so match any single
        # path component for the tree name.
        grep -hv '^[[:space:]]*#' "${files[@]}" 2>/dev/null \
            | grep -ohE 'repos/[^/]+/[a-zA-Z0-9._-]+' \
            | sed 's#.*/##'
    } | sort -u
}
