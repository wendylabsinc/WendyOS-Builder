#!/usr/bin/env bash
# resolve-agent-release.sh — pick the wendyos-agent release an image bakes in.
#
# Reads GitHub release JSON on stdin and prints KEY=VALUE lines for $GITHUB_ENV.
# Errors go to stderr; nothing is printed unless a release resolved.
#
# Inputs (env vars):
#   CHANNEL       stable  — the /releases/latest object (release and PR images)
#                 nightly — the newest prerelease in the /releases list (nightly
#                           images); prereleases only, like the CLI's --nightly
#   ARCH          arm64 | amd64 — whose tarball the sha256 is for
#   PUBLISHED_BY  optional ISO-8601 UTC cutoff for nightly, so every board in a
#                 run, and every re-run, gets the same agent
#
# Output:
#   WENDYOS_AGENT_VERSION  release tag, e.g. 2026.10.27-102715
#   WENDYOS_AGENT_SHA256   sha256 of wendy-agent-linux-<ARCH>-<tag>.tar.gz
set -euo pipefail

: "${ARCH:?ARCH must be arm64 or amd64}"
case "${CHANNEL:-}" in
  stable|nightly) ;;
  *) echo "::error::CHANNEL must be stable or nightly (got '${CHANNEL:-}')" >&2; exit 1 ;;
esac

# GitHub's list order is not tag order, so sort by tag.
selected=$(jq -r --arg channel "$CHANNEL" --arg arch "$ARCH" --arg by "${PUBLISHED_BY:-}" '
  if $channel == "nightly" then
    map(select(.prerelease and (.draft | not)
               and (.tag_name | test("^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}-[0-9]{6}$"))
               and ($by == "" or .published_at <= $by)))
  else [.] end
  | sort_by(.tag_name) | reverse
  | map(.tag_name as $tag
        | {tag: $tag,
           sha: ([.assets[]? | select(.name == "wendy-agent-linux-\($arch)-\($tag).tar.gz") | .digest][0]
                 // "" | sub("^sha256:"; ""))})
  | map(select(.sha | test("^[0-9a-f]{64}$")))
  | first // empty
  | "\(.tag) \(.sha)"')

if [[ -z "$selected" ]]; then
  echo "::error::No $CHANNEL wendyos-agent release has a linux-$ARCH tarball with a sha256 digest" >&2
  exit 1
fi

read -r version sha <<<"$selected"
echo "Resolved wendyos-agent $version for $ARCH from the $CHANNEL channel (sha256=$sha)" >&2
printf 'WENDYOS_AGENT_VERSION=%s\nWENDYOS_AGENT_SHA256=%s\n' "$version" "$sha"
