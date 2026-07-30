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

# --- prune_backups (WDY-2185) -----------------------------------------------

# seed_backups DIR N — N backups named as install_binary names them, oldest
# first. The suffix is a real time, so step HHMMSS rather than printing %06d
# and emitting impossible times like 000060.
seed_backups() {
    local dir="$1" n="$2" i
    for (( i = 0; i < n; i++ )); do
        : > "${dir}/${BINARY_NAME}.backup.20260101_$(
            printf '%02d%02d%02d' $(( i / 3600 )) $(( (i / 60) % 60 )) $(( i % 60 ))
        )"
    done
}

# survivors DIR — remaining backup suffixes, space separated, in glob order.
survivors() {
    local dir="$1" f out=""
    for f in "${dir}/${BINARY_NAME}".backup.*; do
        [ -f "$f" ] && out="${out}${out:+ }${f##*.backup.}"
    done
    echo "$out"
}

# assert_prune N WANT — seed N backups, prune, expect exactly WANT left.
assert_prune() {
    local n="$1" want="$2" tmp got
    tmp=$(mktemp -d)
    BACKUP_DIR="$tmp"
    seed_backups "$tmp" "$n"
    prune_backups >/dev/null 2>&1
    got=$(survivors "$tmp")
    if [[ "$got" == "$want" ]]; then
        ok "prune_backups keeps the newest 2 of $n"
    else
        bad "prune_backups with $n -> '$got' (want '$want')"
    fi
    rm -rf "$tmp"
}

assert_prune 0 ""
assert_prune 1 "20260101_000000"
assert_prune 2 "20260101_000000 20260101_000001"
assert_prune 3 "20260101_000001 20260101_000002"
assert_prune 5 "20260101_000003 20260101_000004"
# The backlog found on the device, and a minute boundary.
assert_prune 68 "20260101_000106 20260101_000107"

# perform_update() restores from .latest and nothing else.
tmp=$(mktemp -d)
BACKUP_DIR="$tmp"
seed_backups "$tmp" 5
: > "$tmp/${BINARY_NAME}.latest"
prune_backups >/dev/null 2>&1
if [[ -f "$tmp/${BINARY_NAME}.latest" && "$(survivors "$tmp")" == "20260101_000003 20260101_000004" ]]; then
    ok "prune_backups leaves ${BINARY_NAME}.latest alone"
else
    bad "prune_backups removed .latest or the wrong backups"
fi
rm -rf "$tmp"

# By name, not mtime — a restored or rsynced backup dir carries arbitrary ones.
tmp=$(mktemp -d)
BACKUP_DIR="$tmp"
seed_backups "$tmp" 4
touch -t 200001010000 "$tmp/${BINARY_NAME}.backup.20260101_000003"
touch -t 203001010000 "$tmp/${BINARY_NAME}.backup.20260101_000000"
prune_backups >/dev/null 2>&1
if [[ "$(survivors "$tmp")" == "20260101_000002 20260101_000003" ]]; then
    ok "prune_backups orders by name, not mtime"
else
    bad "prune_backups mtime independence -> '$(survivors "$tmp")'"
fi
rm -rf "$tmp"

# Wall clock, not a counter: a backwards clock step names a newer backup older
# and discards it. The count bound still holds, which is what WDY-2185 needs.
tmp=$(mktemp -d)
BACKUP_DIR="$tmp"
: > "$tmp/${BINARY_NAME}.backup.20260101_120000"
: > "$tmp/${BINARY_NAME}.backup.20260101_120001"
: > "$tmp/${BINARY_NAME}.backup.20250101_000000"   # taken last, clock stepped back
prune_backups >/dev/null 2>&1
if [[ "$(survivors "$tmp")" == "20260101_120000 20260101_120001" ]]; then
    ok "prune_backups holds the count bound across a backwards clock step"
else
    bad "prune_backups clock step -> '$(survivors "$tmp")'"
fi
rm -rf "$tmp"

# Globs sort by collating sequence, not bytes (POSIX XCU 2.13.3); LC_ALL=C
# pins it.
tmp=$(mktemp -d)
BACKUP_DIR="$tmp"
seed_backups "$tmp" 5
LC_ALL=en_US.UTF-8 prune_backups >/dev/null 2>&1
if [[ "$(survivors "$tmp")" == "20260101_000003 20260101_000004" ]]; then
    ok "prune_backups is unaffected by the ambient locale"
else
    bad "prune_backups under en_US.UTF-8 -> '$(survivors "$tmp")'"
fi
rm -rf "$tmp"

# main() prunes before anything else, so under `set -e` a non-zero return on an
# empty or missing dir would abort the update check on every tick.
tmp=$(mktemp -d)
BACKUP_DIR="$tmp"
if prune_backups >/dev/null 2>&1 && [[ -z "$(survivors "$tmp")" ]]; then
    ok "prune_backups on an empty dir is a no-op"
else
    bad "prune_backups on an empty dir returned non-zero or removed something"
fi
rm -rf "$tmp"

# shellcheck disable=SC2034  # read by the sourced prune_backups
BACKUP_DIR="/nonexistent/wendy-agent-backups"
if prune_backups >/dev/null 2>&1; then
    ok "prune_backups on a missing dir is a no-op"
else
    bad "prune_backups on a missing dir returned non-zero"
fi

# Everything above tests the updater's copy; the download script has its own.
updater_prune=$(sed -n '/^KEEP_BACKUPS=/,/^}/p' "${SCRIPT_DIR}/wendyos-agent-updater.sh")
download_prune=$(sed -n '/^KEEP_BACKUPS=/,/^}/p' "${SCRIPT_DIR}/download-wendyos-agent.sh")
if [[ -n "$updater_prune" && "$updater_prune" == "$download_prune" ]]; then
    ok "prune_backups is identical in both scripts"
else
    bad "prune_backups has drifted between the updater and the download script"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
