#!/usr/bin/env bash
#
# Reclaims containerd data stranded on the OS root slot, hidden underneath
# the /var/lib/containerd bind mount from /data/containerd
# (var-lib-containerd.mount). If containerd ever started before that bind
# was in place -- e.g. a boot where data.mount failed and containerd came up
# on the root slot anyway (WDY-3127) -- its data landed on the small A/B
# rootfs instead of /data, and stays there, invisible, once the bind mount
# is back. Left alone, it fills the root slot across reboots.
#
# The unit that runs this (wendyos-rootfs-shadow-clean.service) is ordered
# Requires=/After= var-lib-containerd.mount and Before=containerd.service, so
# this always runs with the real bind in place and before containerd could
# write anything new under it. The mountpoint check below is a defensive
# second confirmation, not the primary guard.
set -euo pipefail

log() { printf '[wendyos-rootfs-shadow-clean] %s\n' "$*"; }

# Only this path is ever touched -- deliberately not parameterised.
TARGET=/var/lib/containerd

if ! mountpoint -q "${TARGET}"; then
    log "${TARGET} is not a mountpoint; nothing to do"
    exit 0
fi

tmp="$(mktemp -d /run/wendyos-rootfs-shadow.XXXXXX)"
# A non-recursive bind of / exposes the root filesystem's own directory
# entries without any of its submounts, so "${tmp}${TARGET}" resolves to the
# rootfs directory hidden underneath the bind mount above, not to the bind's
# target -- it is safe to delete through.
mount --bind / "${tmp}"
trap 'umount "${tmp}" 2>/dev/null || true; rmdir "${tmp}" 2>/dev/null || true' EXIT

# Never delete through a real mount. Confirm the shadow root bound cleanly,
# and that its copy of ${TARGET} did NOT itself come up as a mountpoint --
# that would mean the bind above somehow followed the live mount, and the
# find -delete below would be operating on the real /data/containerd instead
# of the shadowed rootfs directory.
if ! mountpoint -q "${tmp}"; then
    log "ERROR: ${tmp} is not a mountpoint after mount --bind /; aborting"
    exit 1
fi
if mountpoint -q "${tmp}${TARGET}"; then
    log "ERROR: ${tmp}${TARGET} is itself a mountpoint (the shadow root leaked the live bind); aborting rather than risk deleting real data"
    exit 1
fi

first_entry="$(find "${tmp}${TARGET}" -mindepth 1 -print -quit)"
if [ -n "${first_entry}" ]; then
    size="$(du -sh "${tmp}${TARGET}" 2>/dev/null | cut -f1)"
    log "found containerd data stranded under the root slot (${size})"
    find "${tmp}${TARGET}" -mindepth 1 -delete
    log "reclaimed ${size} from the OS root slot (WDY-3127)"
else
    log "nothing to reclaim"
fi
