#!/bin/sh
# Merge WendyOS driver add-ons stored on /data onto the running system.
#
# systemd-sysext merges an add-on's /usr read-only, so a merged .ko would be missing from
# modules.dep. Mutable mode gives the merge a writable layer to hold depmod's output;
# ephemeral discards it on unmerge, so the index is rebuilt rather than persisted.
# Idempotent: safe to re-run at boot and after every install.
#
# Trust: signatures are not verified here — anything able to write /data can load a module
# as root. /data must be a trusted store.
set -u

STORE=/data/extensions
ENABLED="$STORE/enabled"
RUNDIR=/run/extensions
KVER="$(uname -r)"
# Shipped inside the add-on image, so these resolve only once it is merged.
MODLOADDIR="/usr/lib/modules-load.d"
RELDIR="/usr/lib/extension-release.d"

# Restrict to /usr. The default set also covers /opt, where an ephemeral layer would
# discard runtime writes to /opt/wendy and /opt/containerd on unmerge.
SYSTEMD_SYSEXT_HIERARCHIES=/usr
export SYSTEMD_SYSEXT_HIERARCHIES

has_enabled() {
    for f in "$ENABLED"/*.raw; do
        [ -e "$f" ] && return 0
    done
    return 1
}

has_stale_links() {
    for l in "$RUNDIR"/*; do
        [ -L "$l" ] && return 0
    done
    return 1
}

# Exit early only on a device that has never had add-ons. Any leftover state means a
# previous run merged something, so removing the last add-on still unmerges it here rather
# than leaving /usr merged until the next boot.
if ! has_enabled && ! has_stale_links && ! mountpoint -q /usr; then
    exit 0
fi

mkdir -p "$ENABLED" "$STORE/modules-load.d" "$RUNDIR"
# Obsolete state from an earlier layout, one directory per kernel version.
rm -rf "$STORE/modules-overlay"

# systemd-sysext searches /run/extensions, so link the enabled images into it. Stale links
# are removed with a loop because busybox find has no -delete.
for link in "$RUNDIR"/*; do
    [ -L "$link" ] && rm -f "$link"
done
for raw in "$ENABLED"/*.raw; do
    [ -e "$raw" ] || continue
    ln -sf "$raw" "$RUNDIR/$(basename "$raw")"
done

# Nothing left to merge: unmerge outright, since a refresh would leave an empty mutable
# layer stacked on /usr.
if ! has_enabled; then
    if ! systemd-sysext unmerge; then
        echo "wendyos-sysext-apply: systemd-sysext unmerge failed" >&2
        exit 1
    fi
    exit 0
fi

# --always-refresh: reinstalling a driver reuses the image filename, which on its own looks
# like no change.
if ! systemd-sysext --mutable=ephemeral --always-refresh=yes refresh; then
    echo "wendyos-sysext-apply: systemd-sysext refresh failed" >&2
    exit 1
fi

if ! depmod -a "$KVER"; then
    echo "wendyos-sysext-apply: depmod failed" >&2
    exit 1
fi

# udev rules shipped by an add-on appear only after the merge, long after udevd read its set.
udevadm control --reload >/dev/null 2>&1 || true

# The module index can be stale immediately after the merge, so confirm the name resolves
# before loading it and rebuild once if it does not.
depmod_rebuilt=0
resolves() {
    modprobe --dry-run --quiet -- "$1" 2>/dev/null && return 0
    [ "$depmod_rebuilt" = 1 ] && return 1
    depmod_rebuilt=1
    echo "wendyos-sysext-apply: module index did not resolve '$1', rebuilding" >&2
    depmod -a "$KVER" || return 1
    modprobe --dry-run --quiet -- "$1" 2>/dev/null
}

# Load each add-on's modules, one name per line with '#' comments allowed. A /data override
# wins over the list baked into the image. A failure is reported but does not stop the rest.
rc=0
for raw in "$ENABLED"/*.raw; do
    [ -e "$raw" ] || continue
    name=$(basename "$raw" .raw)

    # systemd has no kernel criterion, so an add-on built for an older kernel still merges
    # after an OTA. Skip it: failing the unit could roll back an A/B trial boot.
    rel="$RELDIR/extension-release.$name"
    if [ -f "$rel" ]; then
        want=$(sed -n 's/^WENDYOS_KERNEL=//p' "$rel")
        if [ -n "$want" ] && [ "$want" != "$KVER" ]; then
            echo "wendyos-sysext-apply: $name is for kernel $want, running $KVER — skipping" >&2
            continue
        fi
    fi

    conf="$STORE/modules-load.d/$name.conf"
    [ -f "$conf" ] || conf="$MODLOADDIR/$name.conf"
    [ -f "$conf" ] || continue
    while IFS= read -r mod || [ -n "$mod" ]; do
        # Trim only leading and trailing blanks: removing inner whitespace would turn a
        # malformed 'snd usb' into a plausible 'sndusb' and defeat the check below.
        mod=$(printf '%s' "$mod" | sed -e 's/\r//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$mod" in
            ''|\#*) continue ;;
            *[!A-Za-z0-9_.-]*)
                echo "wendyos-sysext-apply: bad module name '$mod'" >&2; rc=1; continue ;;
        esac
        resolves "$mod" || { echo "wendyos-sysext-apply: $mod not in the module index" >&2; rc=1; continue; }
        modprobe -- "$mod" || { echo "wendyos-sysext-apply: modprobe $mod failed" >&2; rc=1; }
    done < "$conf"
done

# Re-evaluate devices that already existed, so an add-on's rules apply to hardware present
# before its module loaded.
udevadm trigger >/dev/null 2>&1 || true

exit "$rc"
