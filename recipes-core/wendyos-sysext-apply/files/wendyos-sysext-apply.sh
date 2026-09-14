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

# Optional: the add-on this run is for. The exit status then reports only that one,
# so a broken add-on already on the device cannot fail an unrelated install.
SUBJECT="${1:-}"

STORE=/data/extensions
ENABLED="$STORE/enabled"
RUNDIR=/run/extensions
KVER="$(uname -r)"
# Shipped inside the add-on image, so these resolve only once it is merged.
MODLOADDIR="/usr/lib/modules-load.d"
RELDIR="/usr/lib/extension-release.d"
ACTIVATIONDIR="/usr/lib/wendyos-driver-activation.d"

# The boot unit and an agent-driven install rewrite the same merge, so only one
# runs at a time. The guard variable stops the re-exec from recursing.
if [ -z "${WENDYOS_SYSEXT_APPLY_LOCKED:-}" ] && command -v flock >/dev/null 2>&1; then
    export WENDYOS_SYSEXT_APPLY_LOCKED=1
    exec flock /run/wendyos-sysext-apply.lock "$0" "$@"
fi

# Restrict to /usr. The default set also covers /opt, where an ephemeral layer would
# discard runtime writes to /opt/wendy and /opt/containerd on unmerge.
SYSTEMD_SYSEXT_HIERARCHIES=/usr
export SYSTEMD_SYSEXT_HIERARCHIES

# Buckets, in precedence order: this kernel, then add-ons pinning none, then the
# pre-keyed flat layout (this script runs long before the agent that migrates it).
# Keying by kernel is what lets a rebuild be staged before the OTA that needs it,
# and lets a rollback still find the copy built for the slot it returns to.
has_images() {
    for f in "$ENABLED/$KVER"/*.raw "$ENABLED/any"/*.raw "$ENABLED"/*.raw; do
        [ -e "$f" ] && return 0
    done
    return 1
}

has_links() {
    for l in "$RUNDIR"/*; do
        [ -L "$l" ] && return 0
    done
    return 1
}

# Exit early only on a device that has never had add-ons. Any leftover state means a
# previous run merged something, so removing the last add-on still unmerges it here rather
# than leaving /usr merged until the next boot.
if ! has_images && ! has_links && ! mountpoint -q /usr; then
    exit 0
fi

mkdir -p "$ENABLED/$KVER" "$ENABLED/any" "$STORE/modules-load.d" "$RUNDIR"
# Obsolete state from an earlier layout, one directory per kernel version.
rm -rf "$STORE/modules-overlay"

# systemd-sysext searches /run/extensions, so link the enabled images into it. Stale links
# are removed with a loop because busybox find has no -delete.
for link in "$RUNDIR"/*; do
    [ -L "$link" ] && rm -f "$link"
done
for raw in "$ENABLED/$KVER"/*.raw "$ENABLED/any"/*.raw "$ENABLED"/*.raw; do
    [ -e "$raw" ] || continue
    # First wins: -sf would let a later bucket override the kernel-specific copy.
    link="$RUNDIR/$(basename "$raw")"
    [ -e "$link" ] || ln -s "$raw" "$link"
done

# Nothing left to merge: unmerge outright, since a refresh would leave an empty mutable
# layer stacked on /usr.
if ! has_links; then
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

valid_module_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_interface_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_service_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_.@:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

pci_device_present() {
    wanted=$1
    for device_path in /sys/bus/pci/devices/*; do
        [ -f "$device_path/vendor" ] || continue
        [ -f "$device_path/device" ] || continue
        IFS= read -r vendor < "$device_path/vendor" || continue
        IFS= read -r device < "$device_path/device" || continue
        present=$(printf '%s:%s' "${vendor#0x}" "${device#0x}" | tr 'A-F' 'a-f')
        [ "$present" = "$wanted" ] && return 0
    done
    return 1
}

# Load each add-on's modules, one name per line with '#' comments allowed. A /data override
# wins over the list baked into the image. A failure is reported but does not stop the rest.
# Driven by the links, so each add-on is handled once at the precedence set above.
rc=0
for link in "$RUNDIR"/*.raw; do
    [ -e "$link" ] || continue
    name=$(basename "$link" .raw)

    # Backstop for the flat layout, whose entries are not sorted by kernel. Skipped
    # rather than failed: failing the unit could roll back an A/B trial boot.
    rel="$RELDIR/extension-release.$name"
    if [ -f "$rel" ]; then
        want=$(sed -n 's/^WENDYOS_KERNEL=//p' "$rel")
        if [ -n "$want" ] && [ "$want" != "$KVER" ]; then
            echo "wendyos-sysext-apply: $name is for kernel $want, running $KVER — skipping" >&2
            continue
        fi
    fi

    # Every add-on is still handled and every failure logged; fail decides whose
    # problem reaches the exit status for an agent-driven subject installation.
    fail=1
    [ -n "$SUBJECT" ] && [ "$SUBJECT" != "$name" ] && fail=0

    # A replacement stack must not evict the stock driver on hardware it does not serve.
    # Multiple PCI declarations are alternatives: one matching endpoint activates the
    # add-on. Unknown or malformed directives fail only the subject installation.
    activation="$ACTIVATIONDIR/$name.conf"
    activate=1
    if [ -f "$activation" ]; then
        pci_declared=0
        pci_matched=0
        activation_bad=0
        while read -r directive value extra || [ -n "${directive:-}${value:-}${extra:-}" ]; do
            case "${directive:-}" in
                ''|\#*) continue ;;
                pci)
                    pci_declared=1
                    case "${value:-}" in
                        ????':'????)
                            hex="${value%:*}${value#*:}"
                            case "$hex" in *[!0-9a-fA-F]*) activation_bad=1; continue ;; esac
                            ;;
                        *) activation_bad=1; continue ;;
                    esac
                    [ -z "${extra:-}" ] || { activation_bad=1; continue; }
                    normalized=$(printf '%s' "$value" | tr 'A-F' 'a-f')
                    pci_device_present "$normalized" && pci_matched=1
                    ;;
                replace|reload)
                    [ -z "${extra:-}" ] && valid_module_name "${value:-}" \
                        || activation_bad=1
                    ;;
                restore-wifi-connection)
                    [ -z "${extra:-}" ] && valid_interface_name "${value:-}" \
                        || activation_bad=1
                    ;;
                restart-service)
                    [ -z "${extra:-}" ] && valid_service_name "${value:-}" \
                        || activation_bad=1
                    ;;
                *) activation_bad=1 ;;
            esac
        done < "$activation"

        if [ "$activation_bad" = 1 ]; then
            echo "wendyos-sysext-apply: malformed activation metadata for $name" >&2
            rc=$((rc|fail))
            continue
        fi
        if [ "$pci_declared" = 1 ] && [ "$pci_matched" = 0 ]; then
            echo "wendyos-sysext-apply: $name has no matching PCI device — skipping" >&2
            continue
        fi
    fi

    # Ordinary module loads are idempotent, but replacement/reload activation is not.
    # Run those disruptive operations only at boot or for the explicitly installed
    # subject, never while applying an unrelated add-on.
    activate_now=0
    if [ -z "$SUBJECT" ] || [ "$SUBJECT" = "$name" ]; then
        activate_now=1
    fi
    restore_state=""
    if [ "$activate" = 1 ] && [ "$activate_now" = 1 ] && [ -f "$activation" ]; then
        # Remember the exact active profile before its netdev disappears. Asking
        # NetworkManager merely to reconnect the new device is insufficient for Wi-Fi:
        # without an AP path it tries to create a new incomplete connection instead of
        # selecting the saved one.
        restore_state=$(mktemp "/run/wendyos-driver-restore.$name.XXXXXX")
        while read -r directive interface extra || [ -n "${directive:-}${interface:-}${extra:-}" ]; do
            [ "${directive:-}" = restore-wifi-connection ] || continue
            command -v nmcli >/dev/null 2>&1 || continue
            connection_uuid=$(nmcli -g GENERAL.CON-UUID device show "$interface" 2>/dev/null \
                | sed -n '1{s/\r//g;p;}')
            case "$connection_uuid" in
                ''|--|*[!A-Fa-f0-9-]*) continue ;;
            esac
            printf '%s %s\n' "$interface" "$connection_uuid" >> "$restore_state"
        done < "$activation"

        unload_failed=0
        while read -r directive mod extra || [ -n "${directive:-}${mod:-}${extra:-}" ]; do
            case "${directive:-}" in
                replace|reload)
                    module_sysname=$(printf '%s' "$mod" | tr '-' '_')
                    [ -d "/sys/module/$module_sysname" ] || continue
                    if ! modprobe -r -- "$mod"; then
                        echo "wendyos-sysext-apply: could not unload $mod for $name" >&2
                        rc=$((rc|fail))
                        unload_failed=1
                        break
                    fi
                    ;;
            esac
        done < "$activation"
        if [ "$unload_failed" = 1 ]; then
            # Inserting replacements over a partially resident stack can mix
            # incompatible internal kernel APIs. Let the installer report failure
            # and restore the old image; a reboot may be needed for removed modules.
            echo "wendyos-sysext-apply: replacement aborted for $name; reboot may be required" >&2
            rm -f "$restore_state"
            continue
        fi
    fi

    conf="$STORE/modules-load.d/$KVER/$name.conf"
    [ -f "$conf" ] || conf="$STORE/modules-load.d/any/$name.conf"
    [ -f "$conf" ] || conf="$STORE/modules-load.d/$name.conf"
    [ -f "$conf" ] || conf="$MODLOADDIR/$name.conf"
    if [ -f "$conf" ]; then
        while IFS= read -r mod || [ -n "$mod" ]; do
            # Trim only leading and trailing blanks: removing inner whitespace would turn
            # a malformed 'snd usb' into a plausible 'sndusb' and defeat the check below.
            mod=$(printf '%s' "$mod" | sed -e 's/\r//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            case "$mod" in
                ''|\#*) continue ;;
                *[!A-Za-z0-9_.-]*)
                    echo "wendyos-sysext-apply: bad module name '$mod'" >&2; rc=$((rc|fail)); continue ;;
            esac
            resolves "$mod" || { echo "wendyos-sysext-apply: $mod not in the module index" >&2; rc=$((rc|fail)); continue; }
            modprobe -- "$mod" || { echo "wendyos-sysext-apply: modprobe $mod failed" >&2; rc=$((rc|fail)); }
        done < "$conf"
    fi

    if [ "$activate" = 1 ] && [ "$activate_now" = 1 ] && [ -f "$activation" ]; then
        while read -r directive mod extra || [ -n "${directive:-}${mod:-}${extra:-}" ]; do
            [ "${directive:-}" = reload ] || continue
            resolves "$mod" \
                || { echo "wendyos-sysext-apply: $mod not in the module index" >&2; rc=$((rc|fail)); continue; }
            modprobe -- "$mod" \
                || { echo "wendyos-sysext-apply: modprobe $mod failed" >&2; rc=$((rc|fail)); }
        done < "$activation"
    fi

    if [ "$activate" = 1 ] && [ "$activate_now" = 1 ] && [ -f "$activation" ]; then
        while read -r directive unit extra || [ -n "${directive:-}${unit:-}${extra:-}" ]; do
            [ "${directive:-}" = restart-service ] || continue
            if ! systemctl try-restart "$unit"; then
                echo "wendyos-sysext-apply: could not restart $unit for $name" >&2
                rc=$((rc|fail))
            fi
        done < "$activation"
    fi

    if [ -n "$restore_state" ]; then
        # Module insertion emits the device uevent, but NetworkManager may not have
        # created its new device object by the time modprobe returns.
        udevadm settle --timeout=10 >/dev/null 2>&1 || true
        while read -r interface connection_uuid; do
            [ -n "$interface" ] || continue
            [ -n "$connection_uuid" ] || continue
            attempts=0
            # Intel regulatory initialization took about 11 seconds on Thor after the
            # fresh supplicant acquired the recreated PHY, so allow a bounded 30-second
            # window for both device availability and the first real scan result.
            while [ "$attempts" -lt 30 ]; do
                nm_state=$(nmcli -g GENERAL.STATE device show "$interface" 2>/dev/null \
                    | sed -n '1{s/\r//g;p;}')
                case "$nm_state" in
                    30*|40*|50*|60*|70*|80*|90*|100*)
                        nmcli device wifi rescan ifname "$interface" >/dev/null 2>&1 || true
                        if nmcli -t -f SSID device wifi list ifname "$interface" 2>/dev/null \
                            | sed '/^$/d' | grep -q .; then
                            break
                        fi
                        ;;
                esac
                attempts=$((attempts+1))
                sleep 1
            done
            if ! nmcli connection up uuid "$connection_uuid" ifname "$interface"; then
                # No active profile at install time is normal (for example first setup),
                # so restoration is best-effort and does not make the driver unhealthy.
                echo "wendyos-sysext-apply: could not restore $interface connection" >&2
            fi
        done < "$restore_state"
        rm -f "$restore_state"
    fi
done

# Re-evaluate devices that already existed, so an add-on's rules apply to hardware present
# before its module loaded.
udevadm trigger >/dev/null 2>&1 || true

exit "$rc"
