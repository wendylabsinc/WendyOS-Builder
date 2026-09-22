#!/bin/sh
# Merge WendyOS driver add-ons stored on /data onto the running system.
#
# Each image merges only metadata and an inert private payload. Mutable mode supplies the
# writable /usr layer where eligible payloads are linked into the live module, firmware,
# and udev paths and where depmod writes its index. Ephemeral discards that derived state
# on unmerge; no package-selection metadata persists across boots.
# Idempotent: safe to re-run at boot and after every install.
#
# Trust: signatures are not verified here — anything able to write /data can load a module
# as root. /data must be a trusted store.
set -u
LC_ALL=C
export LC_ALL

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
PAYLOADDIR="/usr/lib/wendyos-driver-payloads"
EXPOSEDMODDIR="/usr/lib/modules/$KVER/updates/wendyos"

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

PLAN=$(mktemp -d "/run/wendyos-driver-plan.XXXXXX") || exit 1
# A signal must never erase the journal and then resume activation. A command
# may have been interrupted mid-mutation, so do not claim a clean rollback.
trap 'rm -rf "$PLAN"' 0
# shellcheck disable=SC2317,SC2329 # Invoked by the signal traps below.
interrupted() {
    trap '' 1 2 15
    echo "wendyos-sysext-apply: interrupted; activation state uncertain, reboot required" >&2
    exit "$1"
}
trap 'interrupted 129' 1
trap 'interrupted 130' 2
trap 'interrupted 143' 15
# Shared across all interfaces, packages and rollback attempts. Leave time for
# module recovery inside the agent's two-minute apply deadline.
WIFI_DEADLINE=$(($(date +%s) + 60))
CLAIMS="$PLAN/claims"
: > "$CLAIMS"

# Private payloads are not in a module search path yet. Rebuild first so unloading and
# rollback still resolve the previously active (normally base-system) drivers.
if ! depmod -a "$KVER"; then
    echo "wendyos-sysext-apply: depmod failed" >&2
    exit 1
fi

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
    case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; *) return 0 ;; esac
}

valid_interface_name() {
    case "$1" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; *) return 0 ;; esac
}

valid_service_name() {
    case "$1" in ''|-*|*[!A-Za-z0-9_.@:-]*) return 1 ;; *) return 0 ;; esac
}

module_sysname() {
    printf '%s' "$1" | tr '-' '_'
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

# Claims cover every resource a package would expose. Module names use the kernel's
# dash/underscore equivalence, so foo-bar.ko and foo_bar.ko collide. A package is atomic:
# one collision suppresses its entire payload.
make_claims() {
    package=$1
    payload=$2
    package_claims="$PLAN/$package.claims"
    : > "$package_claims"
    for source in "$payload/modules/$KVER"/*.ko; do
        [ -f "$source" ] || continue
        mod=$(basename "$source" .ko)
        printf 'module:%s\n' "$(module_sysname "$mod")" >> "$package_claims"
    done
    if [ -d "$payload/firmware" ]; then
        find "$payload/firmware" \( -type f -o -type l \) -print | LC_ALL=C sort > "$PLAN/$package.firmware"
        while IFS= read -r source; do
            printf 'firmware:%s\n' "${source#"$payload/firmware/"}" >> "$package_claims"
        done < "$PLAN/$package.firmware"
    fi
    for source in "$payload/udev"/*; do
        [ -f "$source" ] || continue
        printf 'udev:%s\n' "$(basename "$source")" >> "$package_claims"
    done
}

claim_owner() {
    claim=$1
    awk -F '\t' -v claim="$claim" '$1 == claim { print $2; exit }' "$CLAIMS"
}

payload_collision() {
    package=$1
    while IFS= read -r claim; do
        owner=$(claim_owner "$claim")
        if [ -n "$owner" ]; then
            echo "wendyos-sysext-apply: $package conflicts with earlier package $owner on $claim — skipping" >&2
            return 0
        fi
    done < "$PLAN/$package.claims"
    return 1
}

reserve_claims() {
    package=$1
    while IFS= read -r claim; do
        printf '%s\t%s\n' "$claim" "$package" >> "$CLAIMS"
    done < "$PLAN/$package.claims"
}

expose_one() {
    source=$1
    destination=$2
    exposed=$3
    mkdir -p "$(dirname "$destination")" || return 1
    backup="$exposed.backup.$(wc -l < "$exposed" | tr -d ' ')"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        cp -a "$destination" "$backup" || return 1
        rm -f "$destination" || return 1
    fi
    # Record before linking so a failed ln is still covered by package rollback.
    printf '%s\n' "$destination" >> "$exposed" || return 1
    ln -s "$source" "$destination"
}

expose_payload() {
    package=$1
    payload=$2
    exposed="$PLAN/$package.exposed"
    : > "$exposed"
    for source in "$payload/modules/$KVER"/*.ko; do
        [ -f "$source" ] || continue
        expose_one "$source" "$EXPOSEDMODDIR/$package/$(basename "$source")" "$exposed" || return 1
    done
    if [ -d "$payload/firmware" ]; then
        find "$payload/firmware" \( -type f -o -type l \) -print | LC_ALL=C sort > "$PLAN/$package.firmware"
        while IFS= read -r source; do
            relative=${source#"$payload/firmware/"}
            expose_one "$source" "/usr/lib/firmware/$relative" "$exposed" || return 1
        done < "$PLAN/$package.firmware"
    fi
    for source in "$payload/udev"/*; do
        [ -f "$source" ] || continue
        expose_one "$source" "/usr/lib/udev/rules.d/$(basename "$source")" "$exposed" || return 1
    done
}

hide_payload() {
    exposed=$1
    [ -f "$exposed" ] || { echo "wendyos-sysext-apply: missing payload rollback journal" >&2; return 1; }
    index=0
    hide_failed=0
    while IFS= read -r destination; do
        [ -n "$destination" ] || continue
        rm -f "$destination" || hide_failed=1
        backup="$exposed.backup.$index"
        if [ -e "$backup" ] || [ -L "$backup" ]; then
            cp -a "$backup" "$destination" || hide_failed=1
        fi
        index=$((index+1))
    done < "$exposed"
    [ "$hide_failed" = 0 ]
}

preflight_unload() {
    package=$1
    activation=$2
    targets="$PLAN/$package.targets"
    target_sysnames="$PLAN/$package.target-sysnames"
    : > "$targets"
    : > "$target_sysnames"
    while read -r directive mod extra || [ -n "${directive:-}${mod:-}${extra:-}" ]; do
        case "${directive:-}" in replace|reload) ;; *) continue ;; esac
        sysname=$(module_sysname "$mod")
        [ -d "/sys/module/$sysname" ] || continue
        grep -Fqx "$mod" "$targets" 2>/dev/null || printf '%s\n' "$mod" >> "$targets"
        grep -Fqx "$sysname" "$target_sysnames" 2>/dev/null || printf '%s\n' "$sysname" >> "$target_sysnames"
    done < "$activation"
    while IFS= read -r mod; do
        sysname=$(module_sysname "$mod")
        for holder_path in "/sys/module/$sysname/holders"/*; do
            [ -e "$holder_path" ] || continue
            holder=$(basename "$holder_path")
            if ! grep -Fqx "$holder" "$target_sysnames"; then
                echo "wendyos-sysext-apply: cannot replace $mod for $package; loaded module $holder depends on it" >&2
                return 1
            fi
        done
    done < "$targets"
}

rollback_modules() {
    modules=$1
    action=$2
    [ -f "$modules" ] || { echo "wendyos-sysext-apply: missing module rollback journal" >&2; return 1; }
    [ -s "$modules" ] || return 0
    reverse="$modules.reverse"
    awk '{ line[NR]=$0 } END { for (i=NR; i>0; i--) print line[i] }' "$modules" > "$reverse" || return 1
    rollback_failed=0
    while IFS= read -r mod; do
        operation_failed=0
        if [ -n "$action" ]; then
            modprobe "$action" -- "$mod" || operation_failed=1
        else
            modprobe -- "$mod" || operation_failed=1
        fi
        if [ "$operation_failed" = 1 ]; then
            echo "wendyos-sysext-apply: rollback could not apply '${action:-load}' to $mod" >&2
            rollback_failed=1
        fi
    done < "$reverse"
    [ "$rollback_failed" = 0 ]
}

unload_targets() {
    package=$1
    removed="$PLAN/$package.removed"
    : > "$removed"
    while IFS= read -r mod; do
        sysname=$(module_sysname "$mod")
        # modprobe -r can remove newly-unused dependencies as well as its named target.
        [ -d "/sys/module/$sysname" ] || continue
        if ! modprobe -r -- "$mod"; then
            echo "wendyos-sysext-apply: could not unload $mod for $package" >&2
            return 1
        fi
        printf '%s\n' "$mod" >> "$removed"
    done < "$PLAN/$package.targets"
}

load_one() {
    mod=$1
    inserted=$2
    resolves "$mod" || { echo "wendyos-sysext-apply: $mod not in the module index" >&2; return 1; }
    sysname=$(module_sysname "$mod")
    was_loaded=0
    [ -d "/sys/module/$sysname" ] && was_loaded=1
    modprobe -- "$mod" || { echo "wendyos-sysext-apply: modprobe $mod failed" >&2; return 1; }
    [ "$was_loaded" = 1 ] || printf '%s\n' "$mod" >> "$inserted"
}

load_conf() {
    conf=$1
    inserted=$2
    while IFS= read -r mod || [ -n "$mod" ]; do
        mod=$(printf '%s' "$mod" | sed -e 's/\r//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$mod" in
            ''|\#*) continue ;;
            *[!A-Za-z0-9_.-]*) echo "wendyos-sysext-apply: bad module name '$mod'" >&2; return 1 ;;
        esac
        load_one "$mod" "$inserted" || return 1
    done < "$conf"
}

# nmcli's --wait bounds activation, while timeout also bounds D-Bus queries.
# A shared deadline prevents multiple interfaces from multiplying that budget.
wifi_nmcli() {
    wifi_wait=$1
    shift
    wifi_remaining=$((WIFI_DEADLINE - $(date +%s)))
    [ "$wifi_remaining" -gt 0 ] || return 124
    [ "$wifi_wait" -le "$wifi_remaining" ] || wifi_wait=$wifi_remaining
    timeout --kill-after=1 "$wifi_wait" nmcli --wait "$wifi_wait" "$@"
}

capture_wifi_state() {
    activation=$1
    restore_state=$2
    while read -r directive interface extra || [ -n "${directive:-}${interface:-}${extra:-}" ]; do
        [ "${directive:-}" = restore-wifi-connection ] || continue
        # On a first install the new driver may create this interface. There
        # cannot be a connection to preserve if the kernel has no device yet.
        [ -e "/sys/class/net/$interface" ] || continue
        if ! command -v nmcli >/dev/null 2>&1; then
            echo "wendyos-sysext-apply: cannot capture $interface connection: nmcli is unavailable" >&2
            return 1
        fi
        if ! connection_uuid=$(wifi_nmcli 5 -g GENERAL.CON-UUID device show "$interface"); then
            echo "wendyos-sysext-apply: cannot capture $interface connection; refusing to unload its driver" >&2
            return 1
        fi
        case "$connection_uuid" in
            ''|--) continue ;; # A successful query found no active connection.
            *[!A-Fa-f0-9-]*)
                echo "wendyos-sysext-apply: invalid connection UUID for $interface" >&2
                return 1 ;;
        esac
        printf '%s %s\n' "$interface" "$connection_uuid" >> "$restore_state" || return 1
    done < "$activation"
}

restore_wifi_state() {
    restore_state=$1
    [ -f "$restore_state" ] || return 1
    [ -s "$restore_state" ] || return 0
    wifi_restore_failed=0
    udevadm settle --timeout=5 >/dev/null 2>&1 || true
    while read -r interface connection_uuid; do
        [ -n "$interface" ] || continue
        attempts=0
        while [ "$attempts" -lt 10 ] && [ "$(date +%s)" -lt "$WIFI_DEADLINE" ]; do
            nm_state=$(wifi_nmcli 5 -g GENERAL.STATE device show "$interface" 2>/dev/null) || nm_state=""
            case "$nm_state" in
                30*|40*|50*|60*|70*|80*|90*|100*) break ;;
            esac
            attempts=$((attempts+1))
            sleep 1
        done
        # NetworkManager can activate hidden profiles too; seeing some unrelated
        # SSID in a scan is neither necessary nor sufficient for restoration.
        if ! wifi_nmcli 15 connection up uuid "$connection_uuid" ifname "$interface"; then
            echo "wendyos-sysext-apply: could not restore $interface connection" >&2
            wifi_restore_failed=1
        fi
    done < "$restore_state"
    [ "$wifi_restore_failed" = 0 ]
}

rollback_package() {
    rollback_incomplete=0
    rollback_modules "$inserted" -r || rollback_incomplete=1
    hide_payload "$PLAN/$name.exposed" || rollback_incomplete=1
    if ! depmod -a "$KVER"; then
        echo "wendyos-sysext-apply: could not rebuild module index during rollback for $name" >&2
        rollback_incomplete=1
    fi
    rollback_modules "$removed" "" || rollback_incomplete=1
    udevadm control --reload >/dev/null 2>&1 || true
    restore_wifi_state "$restore_state" || rollback_incomplete=1
    if [ "$rollback_incomplete" = 0 ]; then
        echo "wendyos-sysext-apply: activation rolled back and prior modules restored for $name" >&2
    else
        echo "wendyos-sysext-apply: activation rollback incomplete for $name; reboot required" >&2
    fi
    [ "$rollback_incomplete" = 0 ]
}

# Globs follow LC_ALL=C, making the first-wins policy stable across boots. Claims are
# reserved only after a package is successfully exposed and loaded, so a broken earlier
# candidate does not prevent a later compatible package from getting a chance.
rc=0
for link in "$RUNDIR"/*.raw; do
    [ -e "$link" ] || continue
    name=$(basename "$link" .raw)
    case "$name" in ''|*[!A-Za-z0-9_.-]*) echo "wendyos-sysext-apply: invalid package name '$name'" >&2; rc=1; continue ;; esac

    rel="$RELDIR/extension-release.$name"
    if [ -f "$rel" ]; then
        want=$(sed -n 's/^WENDYOS_KERNEL=//p' "$rel")
        if [ -n "$want" ] && [ "$want" != "$KVER" ]; then
            echo "wendyos-sysext-apply: $name is for kernel $want, running $KVER — skipping" >&2
            [ "$SUBJECT" != "$name" ] || rc=1
            continue
        fi
    fi

    fail=1
    [ -n "$SUBJECT" ] && [ "$SUBJECT" != "$name" ] && fail=0
    activation="$ACTIVATIONDIR/$name.conf"
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
                replace|reload) [ -z "${extra:-}" ] && valid_module_name "${value:-}" || activation_bad=1 ;;
                restore-wifi-connection) [ -z "${extra:-}" ] && valid_interface_name "${value:-}" || activation_bad=1 ;;
                restart-service) [ -z "${extra:-}" ] && valid_service_name "${value:-}" || activation_bad=1 ;;
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
            [ "$SUBJECT" != "$name" ] || rc=1
            continue
        fi
    fi

    payload="$PAYLOADDIR/$name"
    if [ ! -d "$payload" ]; then
        # Images produced before private payloads remain usable during migration. Their
        # files were already exposed by systemd-sysext, so collision isolation is not
        # possible for them.
        conf="$STORE/modules-load.d/$KVER/$name.conf"
        [ -f "$conf" ] || conf="$STORE/modules-load.d/any/$name.conf"
        [ -f "$conf" ] || conf="$STORE/modules-load.d/$name.conf"
        [ -f "$conf" ] || conf="$MODLOADDIR/$name.conf"
        inserted="$PLAN/$name.inserted"
        : > "$inserted"
        if [ -f "$conf" ] && ! load_conf "$conf" "$inserted"; then
            rc=$((rc|fail))
        fi
        continue
    fi

    make_claims "$name" "$payload"
    if payload_collision "$name"; then
        [ "$SUBJECT" != "$name" ] || rc=1
        continue
    fi

    activate_now=0
    if [ -z "$SUBJECT" ] || [ "$SUBJECT" = "$name" ]; then activate_now=1; fi
    removed="$PLAN/$name.removed"
    inserted="$PLAN/$name.inserted"
    restore_state="$PLAN/$name.restore"
    : > "$removed" && : > "$inserted" && : > "$restore_state" && : > "$PLAN/$name.exposed" || exit 1

    if [ -f "$activation" ] && [ "$activate_now" = 1 ]; then
        if ! preflight_unload "$name" "$activation" || ! capture_wifi_state "$activation" "$restore_state"; then
            rc=$((rc|fail))
            continue
        fi
        if ! unload_targets "$name"; then
            rollback_package || true # Logs incomplete recovery; the original operation already failed.
            rc=$((rc|fail))
            continue
        fi
    fi

    if ! expose_payload "$name" "$payload" || ! depmod -a "$KVER"; then
        echo "wendyos-sysext-apply: could not expose payload for $name" >&2
        rollback_package || true
        rc=$((rc|fail))
        continue
    fi
    depmod_rebuilt=0
    udevadm control --reload >/dev/null 2>&1 || true

    package_failed=0
    # An unrelated subject was already activated by an earlier run; merely restore its
    # exposure after refresh, without another disruptive unload/load cycle.
    if [ ! -f "$activation" ] || [ "$activate_now" = 1 ]; then
        conf="$STORE/modules-load.d/$KVER/$name.conf"
        [ -f "$conf" ] || conf="$STORE/modules-load.d/any/$name.conf"
        [ -f "$conf" ] || conf="$STORE/modules-load.d/$name.conf"
        [ -f "$conf" ] || conf="$payload/modules-load.conf"
        if [ -f "$conf" ] && ! load_conf "$conf" "$inserted"; then
            package_failed=1
        fi
    fi
    if [ "$package_failed" = 0 ] && [ -f "$activation" ] && [ "$activate_now" = 1 ]; then
        while read -r directive mod extra || [ -n "${directive:-}${mod:-}${extra:-}" ]; do
            [ "${directive:-}" = reload ] || continue
            if ! load_one "$mod" "$inserted"; then package_failed=1; break; fi
        done < "$activation"
    fi

    if [ "$package_failed" = 0 ] && [ -f "$activation" ] && [ "$activate_now" = 1 ]; then
        while read -r directive unit extra || [ -n "${directive:-}${unit:-}${extra:-}" ]; do
            [ "${directive:-}" = restart-service ] || continue
            if ! timeout --kill-after=1 15 systemctl try-restart -- "$unit"; then
                echo "wendyos-sysext-apply: could not restart $unit for $name" >&2
                package_failed=1
            fi
        done < "$activation"
        if [ "$package_failed" = 0 ]; then
            restore_wifi_state "$restore_state" || package_failed=1
        fi
    fi
    if [ "$package_failed" != 0 ]; then
        rollback_package || true
        rc=$((rc|fail))
        continue
    fi
    reserve_claims "$name"
done

udevadm trigger >/dev/null 2>&1 || true
exit "$rc"
