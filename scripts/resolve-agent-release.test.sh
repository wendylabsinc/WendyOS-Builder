#!/usr/bin/env bash
# Tests for resolve-agent-release.sh — plain bash, no framework.
#
# Feeds fixture GitHub release JSON on stdin and asserts which agent release
# (tag + tarball sha256) each image channel pins.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVER="$SCRIPT_DIR/resolve-agent-release.sh"

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL - $1"; }

# assert_eq label expected actual
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# assert_fails label rc out — a failure must exit non-zero and print nothing.
assert_fails() {
  assert_eq "$1: exits non-zero" 1 "$([[ $2 -ne 0 ]] && echo 1 || echo 0)"
  assert_eq "$1: no output" "" "$3"
}

# run_resolver CHANNEL ARCH [PUBLISHED_BY] <<<"$json" -> stdout=KEY=VALUE, returns rc.
run_resolver() {
  CHANNEL="$1" ARCH="$2" PUBLISHED_BY="${3:-}" bash "$RESOLVER" 2>/dev/null
}

field() { sed -n "s/^$1=//p"; }

# sha CHAR -> a 64-hex digest made of CHAR, readable in failures.
sha() { printf "$1%.0s" {1..64}; }

# release TAG PRERELEASE DRAFT PUBLISHED ARCH:CHAR... -> one release object with
# the agent tarball (plus its SBOM, which must never be picked) per listed arch.
release() {
  local tag="$1" pre="$2" draft="$3" published="$4"; shift 4
  local assets="" spec arch
  for spec in "$@"; do
    arch="${spec%%:*}"
    assets+="{\"name\":\"wendy-agent-linux-$arch-$tag.spdx.json\",\"digest\":\"sha256:$(sha 0)\"},"
    assets+="{\"name\":\"wendy-agent-linux-$arch-$tag.tar.gz\",\"digest\":\"sha256:$(sha "${spec##*:}")\"},"
  done
  printf '{"tag_name":"%s","prerelease":%s,"draft":%s,"published_at":%s,"assets":[%s]}' \
    "$tag" "$pre" "$draft" "$published" "${assets%,}"
}

# The releases list in GitHub's own order, which is not version order: the
# stable release comes first although newer prereleases exist.
RELEASES="[
  $(release 2026.10.27-091653     false false '"2026-10-27T09:36:32Z"' arm64:a amd64:b),
  $(release 2026.10.27-083339     true  false '"2026-10-27T08:59:09Z"' arm64:c amd64:d),
  $(release 2026.10.27-102715     true  false '"2026-10-27T10:46:37Z"' arm64:e amd64:f),
  $(release 2026.10.27-120000     true  true  null                     arm64:1 amd64:2),
  $(release 2026.10.27-130000-dev true  false '"2026-10-27T13:30:00Z"' arm64:3 amd64:4),
  $(release 2026.10.27-140000     true  false '"2026-10-27T14:30:00Z"' amd64:5)
]"

# Newest eligible prerelease. Skipped: a draft, a branch build, and a release
# whose arm64 tarball is not uploaded yet.
test_nightly_arm64() {
  local out; out=$(run_resolver nightly arm64 <<<"$RELEASES"); local rc=$?
  assert_eq "nightly arm64: exits 0" 0 "$rc"
  assert_eq "nightly arm64: version" 2026.10.27-102715 "$(field WENDYOS_AGENT_VERSION <<<"$out")"
  assert_eq "nightly arm64: sha256"  "$(sha e)"        "$(field WENDYOS_AGENT_SHA256  <<<"$out")"
}

test_nightly_amd64() {
  local out; out=$(run_resolver nightly amd64 <<<"$RELEASES"); local rc=$?
  assert_eq "nightly amd64: exits 0" 0 "$rc"
  assert_eq "nightly amd64: version" 2026.10.27-140000 "$(field WENDYOS_AGENT_VERSION <<<"$out")"
  assert_eq "nightly amd64: sha256"  "$(sha 5)"        "$(field WENDYOS_AGENT_SHA256  <<<"$out")"
}

# A run's boards build at different times; the cutoff gives them one agent.
test_nightly_published_by() {
  local out; out=$(run_resolver nightly arm64 2026-10-27T10:00:00Z <<<"$RELEASES"); local rc=$?
  assert_eq "nightly cutoff: exits 0" 0 "$rc"
  assert_eq "nightly cutoff: version" 2026.10.27-083339 "$(field WENDYOS_AGENT_VERSION <<<"$out")"
}

# A stable newer than every prerelease stays out of a nightly image: the CLI's
# nightly channel is prereleases only, so the image must not be ahead of it.
test_nightly_ignores_newer_stable() {
  local json out
  json="[$(release 2026.10.27-091653 false false '"2026-10-27T09:36:32Z"' arm64:a),
         $(release 2026.10.27-083339 true  false '"2026-10-27T08:59:09Z"' arm64:c)]"
  out=$(run_resolver nightly arm64 <<<"$json"); local rc=$?
  assert_eq "nightly vs newer stable: exits 0" 0 "$rc"
  assert_eq "nightly vs newer stable: version" 2026.10.27-083339 "$(field WENDYOS_AGENT_VERSION <<<"$out")"
}

# Falling back to stable would hide a broken nightly channel, so it is fatal.
test_nightly_without_prerelease_fatal() {
  local out; out=$(run_resolver nightly arm64 <<<"[$(release 2026.10.27-091653 false false null arm64:a)]"); local rc=$?
  assert_fails "nightly without prerelease" "$rc" "$out"
}

# Release and PR images keep /releases/latest, which is a single object.
test_stable_latest() {
  local out; out=$(run_resolver stable arm64 <<<"$(release 2026.10.27-091653 false false null arm64:a amd64:b)"); local rc=$?
  assert_eq "stable: exits 0" 0 "$rc"
  assert_eq "stable: version" 2026.10.27-091653 "$(field WENDYOS_AGENT_VERSION <<<"$out")"
  assert_eq "stable: sha256"  "$(sha a)"        "$(field WENDYOS_AGENT_SHA256  <<<"$out")"
}

# Only the exact file the recipe downloads counts, wherever it is listed.
test_exact_tarball_name() {
  local tag=2026.10.27-091653 json out
  json="{\"tag_name\":\"$tag\",\"prerelease\":false,\"draft\":false,\"assets\":[
    {\"name\":\"wendy-agent-linux-arm64-musl-$tag.tar.gz\",\"digest\":\"sha256:$(sha 9)\"},
    {\"name\":\"wendy-agent-linux-arm64-$tag.tar.gz\",\"digest\":\"sha256:$(sha a)\"}]}"
  out=$(run_resolver stable arm64 <<<"$json"); local rc=$?
  assert_eq "exact name: exits 0" 0 "$rc"
  assert_eq "exact name: sha256" "$(sha a)" "$(field WENDYOS_AGENT_SHA256 <<<"$out")"
}

test_stable_missing_arch_fatal() {
  local out; out=$(run_resolver stable arm64 <<<"$(release 2026.10.27-091653 false false null amd64:b)"); local rc=$?
  assert_fails "stable missing arm64" "$rc" "$out"
}

# A channel paired with the other endpoint's JSON fails instead of guessing.
test_shape_mismatch_fatal() {
  local out rc
  out=$(run_resolver stable arm64 <<<"$RELEASES"); rc=$?
  assert_fails "stable fed the releases list" "$rc" "$out"
  out=$(run_resolver nightly arm64 <<<"$(release 2026.10.27-083339 true false null arm64:c)"); rc=$?
  assert_fails "nightly fed one release" "$rc" "$out"
}

test_unknown_channel_fatal() {
  local out; out=$(run_resolver beta arm64 <<<"$RELEASES"); local rc=$?
  assert_fails "unknown channel" "$rc" "$out"
}

test_nightly_arm64
test_nightly_amd64
test_nightly_published_by
test_nightly_ignores_newer_stable
test_nightly_without_prerelease_fatal
test_stable_latest
test_exact_tarball_name
test_stable_missing_arch_fatal
test_shape_mismatch_fatal
test_unknown_channel_fatal

echo
echo "===================="
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
