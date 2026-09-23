#!/usr/bin/env bash
# Select a devkit without substituting an older kernel for a failed OS build.
# Exit 1 skips a device without a devkit; exit 2 reports a broken build contract.
set -euo pipefail
dev=$1
inventory=${DEVICE_INVENTORY:-.github/device-artifacts.json}
report() {
    printf '%s\n' "$*" >&2
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}
fail() { report "::error::$*"; exit 2; }
[[ "$dev" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid device identity"

if [[ -n "${OS_DEVICES:-}" ]]; then
    # Only opted-in machines in the OS matrix owe this run a devkit. Aliases
    # follow their canonical device; other machines may legitimately have none.
    expected=$(jq -r --arg dev "$dev" --arg devices "$OS_DEVICES" '
      to_entries[] | select(.value.driver_devkit == true)
      | (.key | split("/")[0]) as $canonical
      | select($canonical == $dev or .value.manifest_alias == $dev)
      | select(($devices | split(" ") | index($canonical)) != null) | .key' "$inventory")
    [[ -n "$expected" ]] || exit 1
    [[ -n "${WANT_VERSION:-}" ]] || fail "${dev}: current OS build version is missing"
    shopt -s nullglob
    entries=("${BUILT_ENTRIES:?}"/*.json)
    [[ ${#entries[@]} -gt 0 ]] || fail "${dev}: no OS build metadata from this run; refusing public devkit fallback"
    # Successful OS jobs keep their artifacts when only failed jobs are rerun.
    # The run ID stays fixed across attempts, so do not require their attempt
    # number to match the current publish attempt.
    sel=$(jq -sc --arg dev "$dev" --arg version "$WANT_VERSION" \
      --arg run "${GITHUB_RUN_ID:?}" '
      [.[] | select(.device == $dev or ((.aliases // []) | index($dev)) != null)
        | select(.version == $version and .build_run_id == $run)
        | select(.devkit != null)] | sort_by(.storage) | last
      | if . == null then empty else {version, devkit, nightly, source: "current OS build artifact"} end' "${entries[@]}")
    [[ -n "$sel" ]] || fail "${dev}: no matching devkit from OS build ${GITHUB_RUN_ID}/${GITHUB_RUN_ATTEMPT}; rerun the OS build, refusing fallback"
else
    urls=("${PUBLIC_BASE}/${PREFIX:-}manifests/${dev}.json")
    [[ -z "${PREFIX:-}" ]] || urls+=("${PUBLIC_BASE}/manifests/${dev}.json")
    sel=""
    for url in "${urls[@]}"; do
        if ! manifest=$(curl -sSfL --retry 3 --retry-all-errors "$url" 2>/dev/null); then
            report "${dev}: manifest unavailable at $url"
            continue
        fi
        # A PR-only version does not exist in the public namespace. Only that
        # case (or an unspecified version) permits choosing the newest devkit.
        want=${WANT_VERSION:-}
        if [[ -n "${PREFIX:-}" && "$url" == "${urls[1]}" && "$want" == pr-* ]]; then want=""; fi
        sel=$(jq -c --arg want "$want" --arg source "$url" '
          [.versions // {} | to_entries[] | select(.value.devkit != null)
            | {version: .key, devkit: .value.devkit, nightly: (.value.is_nightly // false), source: $source}]
          | if $want != "" then map(select(.version == $want)) | .[0] else sort_by(.version) | last end
          | . // empty' <<<"$manifest")
        [[ -z "$sel" ]] || break
        report "${dev}: no matching devkit at $url"
    done
    if [[ -z "$sel" ]]; then
        report "${dev}: no devkit published; skipping"
        exit 1
    fi
    if [[ -n "${PREFIX:-}" && "$url" == "${urls[1]}" ]]; then
        report "::warning::${dev}: falling back to PUBLIC devkit for driver-only build: $url"
    fi
fi
report "${dev}: devkit $(jq -r .devkit.kernel_version <<<"$sel") from $(jq -r .version <<<"$sel"); source=$(jq -r .source <<<"$sel"); path=$(jq -r .devkit.path <<<"$sel"); sha256=$(jq -r .devkit.sha256 <<<"$sel")"
printf '%s\n' "$sel"
