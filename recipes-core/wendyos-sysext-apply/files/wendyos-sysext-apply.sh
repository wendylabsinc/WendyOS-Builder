#!/bin/sh
# Merge WendyOS driver add-ons stored on /data onto the running system.
#
# Runs late (after /data is mounted and grown). systemd-sysext merges an add-on's
# /usr content READ-ONLY, so a merged-in .ko is absent from the base modules.dep;
# we stack a writable overlay on the module dir and re-run depmod so modprobe can
# resolve it. This works without systemd-sysext "mutable" mode (systemd 256+).
# Idempotent: safe to re-run every boot and after each install.
#
# Trust: this layer does NOT verify signatures — it merges whatever is under
# /data/extensions and modprobes names from modules-load.d, so anything able to
# write /data can load a module as root. /data must be a trusted store; signing is
# enforced by the agent/OTA layer, not here.
set -u

STORE=/data/extensions
ENABLED="$STORE/enabled"
RUNDIR=/run/extensions
KVER="$(uname -r)"
MODDIR="/usr/lib/modules/$KVER"
OVL="$STORE/modules-overlay/$KVER"

# Nothing to do on a stock device with no add-ons: leave /data and /usr untouched.
if [ -z "$(find "$ENABLED" -maxdepth 1 -name '*.raw' -print -quit 2>/dev/null)" ]; then
    exit 0
fi

mkdir -p "$ENABLED" "$STORE/modules-load.d" "$OVL/upper" "$OVL/work" "$RUNDIR"

# 1. Expose enabled add-ons to systemd-sysext via /run/extensions (tmpfs search
#    dir). Clear stale links first (busybox find lacks -delete, so loop).
for link in "$RUNDIR"/*; do
    [ -L "$link" ] && rm -f "$link"
done
for raw in "$ENABLED"/*.raw; do
    [ -e "$raw" ] || continue
    ln -sf "$raw" "$RUNDIR/$(basename "$raw")"
done

# 2. Tear down any prior module overlay so refresh sees a clean /usr, then merge.
#    (The overlay is a submount of /usr and would block sysext's /usr unmerge.)
umount "$MODDIR" 2>/dev/null || umount -l "$MODDIR" 2>/dev/null || true
if mountpoint -q "$MODDIR"; then
    echo "wendyos-sysext-apply: could not unmount prior overlay on $MODDIR" >&2
fi
if ! systemd-sysext refresh; then
    echo "wendyos-sysext-apply: systemd-sysext refresh failed" >&2
    exit 1
fi

# 3. Stack a writable overlay on the module dir so depmod can index merged modules.
if ! mount -t overlay wendyos-modules \
        -o "lowerdir=$MODDIR,upperdir=$OVL/upper,workdir=$OVL/work" "$MODDIR"; then
    echo "wendyos-sysext-apply: overlay mount on $MODDIR failed" >&2
    exit 1
fi

# 4. Rebuild the unified dependency index (base + all merged add-ons).
if ! depmod -a "$KVER"; then
    echo "wendyos-sysext-apply: depmod failed" >&2
    exit 1
fi

# 5. Load declared modules (one name per line; '#' comments allowed). Best-effort:
#    keep going past a failure but exit non-zero so the unit reflects it.
rc=0
for conf in "$STORE"/modules-load.d/*.conf; do
    [ -e "$conf" ] || continue
    while IFS= read -r mod || [ -n "$mod" ]; do
        mod=$(printf '%s' "$mod" | tr -d '[:space:]')     # strip CR/whitespace
        case "$mod" in
            ''|\#*) continue ;;
            *[!A-Za-z0-9_.-]*)
                echo "wendyos-sysext-apply: bad module name '$mod'" >&2; rc=1; continue ;;
        esac
        modprobe -- "$mod" || { echo "wendyos-sysext-apply: modprobe $mod failed" >&2; rc=1; }
    done < "$conf"
done
exit "$rc"
