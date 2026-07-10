#!/usr/bin/env bash
#
# run-with-stall-watchdog.sh — run a bitbake build and abort it if the
# scheduler wedges (as opposed to merely being slow).
#
# Why this exists: a network do_fetch can hang on an unreachable/slow upstream
# mirror with no effective timeout. When a *sibling* fetch then fails hard,
# bitbake stops launching new tasks and waits for the already-running (hung)
# fetches to finish — which they never do. The build then sits idle for as long
# as the job is allowed to run (GitHub's 6h default) until a human cancels it.
# See run 29087311971 / PR #187: ~5 min of real work, then 82 min wedged on
# systemd/linux-yocto/systemd-boot do_fetch before a manual cancel.
#
# The signal: bitbake's knotty UI prints a heartbeat roughly every 600s while
# the scheduler makes no progress:
#
#   Bitbake still alive (no events for 1800s). Active tasks: ...
#
# The number is seconds since the last task state-change. Because the builder
# runs dozens of tasks concurrently, a long zero-event window means the whole
# build is wedged, not that one recipe is compiling slowly — under normal load
# some task starts or finishes every few seconds. So we abort once that window
# crosses STALL_ABORT_SECONDS, killing the entire bitbake process tree so the
# caller ("make build") exits promptly instead of idling for hours.
#
# Usage:
#   STALL_ABORT_SECONDS=1800 run-with-stall-watchdog.sh make build MACHINE=...
#
# Exit codes: the wrapped command's own code on normal completion; 124 (the
# GNU-timeout convention) when the build was killed for stalling.

set -uo pipefail

STALL_ABORT_SECONDS="${STALL_ABORT_SECONDS:-1800}"

if [ "$#" -lt 1 ]; then
  echo "usage: STALL_ABORT_SECONDS=<n> $(basename "$0") <cmd> [args...]" >&2
  exit 2
fi

fifo="$(mktemp -u)"
mkfifo "$fifo"
trap 'rm -f "$fifo"' EXIT

# Run the build in its own process group so a single signal reaches the whole
# tree (bitbake forks a memory-resident server plus task workers; killing only
# the parent would orphan them). Job-control mode (set -m) places a background
# job in a new process group whose PGID equals the job's PID — portable across
# Linux CI and macOS, with no dependency on setsid(1).
set -m
"$@" >"$fifo" 2>&1 &
child=$!
pgid="$child"
set +m

# Forward external cancellation (GitHub "cancel", the job's timeout-minutes) to
# the whole group so nothing is left running on the shared self-hosted runner.
trap 'kill -TERM -"$pgid" 2>/dev/null || true' TERM INT

kill_tree() {
  kill -TERM -"$pgid" 2>/dev/null || true
  # bitbake shuts its workers down on SIGTERM; SIGKILL the stragglers if it
  # hasn't exited within the grace window.
  ( sleep 30; kill -KILL -"$pgid" 2>/dev/null || true ) &
}

stalled=0

# Relay every line unchanged (the CI log must stay complete) while watching for
# the stall heartbeat.
while IFS= read -r line; do
  printf '%s\n' "$line"
  case "$line" in
    *"no events for"*)
      secs="$(printf '%s\n' "$line" | sed -n 's/.*no events for \([0-9]\{1,\}\)s.*/\1/p')"
      if [ -n "$secs" ] && [ "$secs" -ge "$STALL_ABORT_SECONDS" ]; then
        echo "::error::bitbake stalled: no task events for ${secs}s (>= ${STALL_ABORT_SECONDS}s); aborting the wedged build." >&2
        stalled=1
        kill_tree
        break
      fi
      ;;
  esac
done < "$fifo"

if [ "$stalled" -eq 1 ]; then
  wait "$child" 2>/dev/null || true
  exit 124
fi

wait "$child"
exit $?
