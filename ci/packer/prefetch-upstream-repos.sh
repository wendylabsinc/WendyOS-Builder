#!/usr/bin/env bash
#
# Pre-clone the upstream Yocto layer repos pinned in scripts/upstream-repos.env
# into a per-tree subdirectory of <target_dir>. Invoked by
# ci/packer/wendyos-builder.pkr.hcl while baking the CI runner AMI;
# bootstrap.sh's clone_repos picks them up (under
# <cache>/${WENDYOS_LAYER_TREE}/<folder>/) and fetches/checks out instead
# of doing a fresh clone.
#
# The poky monolith has been retired here; "poky" is composed at clone time
# from three split-style upstream repos (bitbake, openembedded-core,
# meta-yocto). See plans/bootstrap-split-poky-migration.md.
#
# Usage:
#   prefetch-upstream-repos.sh <target-dir> <upstream-repos.env path> [<board-repos.overrides>...]
#
# Each repos.overrides file is sourced after the base env, allowing per-board
# SRCREV overrides (e.g. wrynose for Thor) to be baked into the AMI.

set -euo pipefail

target_dir="${1:?target dir required}"
env_file="${2:?upstream-repos.env path required}"
shift 2
overrides=("$@")

prefetch_tree() {
    local tree_dir="${target_dir}/${WENDYOS_LAYER_TREE}"
    mkdir -p "${tree_dir}"
    cd "${tree_dir}"

    # Mirror the (URL, SRCREV, folder) tuples that bootstrap.sh derives from
    # repos[]. Folder names are explicit here for the three split-poky repos
    # (so the mapping URL→folder is unambiguous); the rest match
    # basename-of-URL with .git stripped, like clone_repos in bootstrap.sh.
    declare -A repos=(
        [bitbake]="${URL_BITBAKE}|${SRCREV_BITBAKE}"
        [openembedded-core]="${URL_OECORE}|${SRCREV_OECORE}"
        [meta-yocto]="${URL_METAYOCTO}|${SRCREV_METAYOCTO}"
        [meta-openembedded]="${URL_OE}|${SRCREV_OE}"
        [meta-tegra]="${URL_TEGRA}|${SRCREV_TEGRA}"
        [meta-tegra-community]="${URL_TEGRA_COMM}|${SRCREV_TEGRA_COMM}"
        [meta-virtualization]="${URL_VIRT}|${SRCREV_VIRT}"
        [meta-raspberrypi]="${URL_RPI}|${SRCREV_RPI}"
    )

    for folder in "${!repos[@]}"; do
        IFS='|' read -r url srcrev <<< "${repos[$folder]}"
        printf '[prefetch] %s/%s @ %s\n' "${WENDYOS_LAYER_TREE}" "${folder}" "${srcrev}"

        if [[ ! -d "${folder}/.git" ]]; then
            git clone "${url}" "${folder}"
        fi

        (
            cd "${folder}"
            git fetch --tags origin
            git checkout --detach "${srcrev}"
            git gc --auto
        )
    done
}

# shellcheck disable=SC1090
source "${env_file}"
prefetch_tree

# Apply each per-board overrides file and prefetch its layer tree (if it sets
# a different WENDYOS_LAYER_TREE and SRCREVs). Source again from the base env
# first so overrides only need to set the values they change.
for override_file in "${overrides[@]}"; do
    # shellcheck disable=SC1090
    source "${env_file}"
    # shellcheck disable=SC1090
    source "${override_file}"
    prefetch_tree
done

# Make the cache world-readable so any user the runner spins up under
# (RunsOn defaults to `runner`) can copy / clone from it without sudo.
chmod -R a+rX "${target_dir}"
