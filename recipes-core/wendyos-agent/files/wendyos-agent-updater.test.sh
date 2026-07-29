#!/usr/bin/env bash
# Tests for wendyos-agent-updater.sh — plain bash, no framework, same shape as
# scripts/resolve-artifacts.test.sh.
#
# Covers the two halves of WDY-2038 and the version pin:
#   (a) the installed version is read verbatim, not truncated to a semver
#       prefix. Agent versions are YYYY.MM.DD-HHMMSS; grepping out
#       [0-9]+\.[0-9]+\.[0-9]+ yielded "2026.07.27", which loses to every
#       same-day tag -- so the updater downgraded a newer nightly onto stable
#       and reinstalled stable over itself on every single tick.
#   (b) version_gt agrees with version.CompareVersions in the Go CLI, so the
#       shell updater and `wendy device list` cannot disagree about which of
#       two agents is newer.
#   (c) a WENDYOS_AGENT_VERSION pin converges on exactly that tag, including
#       downgrading onto it, and releases the device back to stable tracking
#       when removed.
#
# Sourced with WENDYOS_UPDATER_LIB_ONLY=1 so main() does not run.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

WENDYOS_UPDATER_LIB_ONLY=1
export WENDYOS_UPDATER_LIB_ONLY
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/wendyos-agent-updater.sh"

# --- version_gt -------------------------------------------------------------
# assert_gt EXPECTED("gt"|"no") A B
assert_gt() {
    local want="$1" a="$2" b="$3" got
    if version_gt "$a" "$b"; then got=gt; else got=no; fi
    if [[ "$got" == "$want" ]]; then
        ok "version_gt '$a' '$b' -> $want"
    else
        bad "version_gt '$a' '$b' -> $got (want $want)"
    fi
}

# The exact WDY-2038 pair: a same-day nightly must beat same-day stable.
assert_gt gt 2026.07.27-081952 2026.07.27-003050
assert_gt no 2026.07.27-003050 2026.07.27-081952
# Identical builds are never "newer" -- this is the reinstall-every-tick guard.
assert_gt no 2026.07.27-003050 2026.07.27-003050
# Day boundary, and a time field that is not valid octal (081952, 003050).
assert_gt gt 2026.07.28-000000 2026.07.27-235959
assert_gt no 2026.07.27-235959 2026.07.28-000000
assert_gt gt 2026.07.27-100000 2026.07.27-081952
assert_gt gt 2027.01.01-000000 2026.12.31-235959
# Ordinary ordering, and the "v" prefix a release tag may carry.
assert_gt gt 2026.07.27-003050 2026.07.20-100000
assert_gt gt v2026.07.27-003050 2026.07.20-100000
assert_gt no 2026.07.20-100000 v2026.07.27-003050
# A truncated value must LOSE to the full tag it was truncated from. This is
# the comparison that produced the downgrade once get_current_version had
# thrown the time away; it stays here to document the mechanism.
assert_gt gt 2026.07.27-003050 2026.07.27
# Empty operands are never newer (no version file, unreadable binary).
assert_gt no "" 2026.07.27-003050
assert_gt no 2026.07.27-003050 ""

# --- get_current_version ----------------------------------------------------
# Point the reader at a stub binary that prints VER, and assert it comes back
# verbatim rather than semver-truncated.
assert_current() {
    local want="$1" printed="$2" tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2034  # read by the sourced get_current_version
    INSTALL_DIR="$tmp"
    VERSION_FILE="$tmp/current-version"
    # shellcheck disable=SC2016  # $1 is for the generated stub, not this shell
    printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "%s"\n' "$printed" > "$tmp/$BINARY_NAME"
    chmod +x "$tmp/$BINARY_NAME"
    local got
    got=$(get_current_version)
    if [[ "$got" == "$want" ]]; then
        ok "get_current_version('$printed') -> '$want'"
    else
        bad "get_current_version('$printed') -> '$got' (want '$want')"
    fi
    rm -rf "$tmp"
}

assert_current 2026.07.27-081952 2026.07.27-081952
assert_current 2026.07.27-003050 2026.07.27-003050
assert_current 2026.06.30-133859-dev 2026.06.30-133859-dev
assert_current dev dev

# Falls back to the stored version file when the binary will not run.
tmp=$(mktemp -d)
# shellcheck disable=SC2034  # read by the sourced get_current_version
INSTALL_DIR="$tmp/absent"
VERSION_FILE="$tmp/current-version"
echo "2026.07.03-194041" > "$VERSION_FILE"
got=$(get_current_version)
if [[ "$got" == "2026.07.03-194041" ]]; then
    ok "get_current_version falls back to the version file"
else
    bad "version-file fallback -> '$got'"
fi
rm -rf "$tmp"

# --- is_dev_build -----------------------------------------------------------
# A dev build outranks a pin: whoever hand-installed it is the most explicit
# actor in the system (WDY-1770).
for v in dev 2026.06.30-133859-dev; do
    if is_dev_build "$v"; then ok "is_dev_build '$v'"; else bad "is_dev_build '$v' should be true"; fi
done
for v in 2026.07.27-003050 "" developer; do
    if is_dev_build "$v"; then bad "is_dev_build '$v' should be false"; else ok "is_dev_build '$v' false"; fi
done

# --- get_target_version -----------------------------------------------------
# Unpinned resolves via the network, so only the pinned branch is unit-tested;
# the unpinned path is covered by the integration run in the PR description.
# shellcheck disable=SC2034  # read by the sourced get_target_version
VERSION="2026.07.27-081952"
got=$(get_target_version)
if [[ "$got" == "2026.07.27-081952" ]]; then
    ok "get_target_version honours the pin"
else
    bad "get_target_version pinned -> '$got'"
fi

# shellcheck disable=SC2034  # read by the sourced get_target_version
VERSION="v2026.07.27-081952"
got=$(get_target_version)
if [[ "$got" == "2026.07.27-081952" ]]; then
    ok "get_target_version strips a leading v from the pin"
else
    bad "get_target_version v-prefixed -> '$got'"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
