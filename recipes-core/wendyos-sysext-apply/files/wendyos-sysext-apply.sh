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
STATEDIR="/usr/lib/wendyos-driver-state"

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
    if [ -n "$SUBJECT" ]; then
        echo "wendyos-sysext-apply: no enabled image named '$SUBJECT' for kernel $KVER" >&2
        exit 1
    fi
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

if [ -n "$SUBJECT" ] && [ ! -e "$RUNDIR/$SUBJECT.raw" ]; then
    echo "wendyos-sysext-apply: no enabled image named '$SUBJECT' for kernel $KVER" >&2
    exit 1
fi

# Nothing left to merge: unmerge outright, since a refresh would leave an empty mutable
# layer stacked on /usr.
if ! has_links; then
    if ! systemd-sysext unmerge; then
        echo "wendyos-sysext-apply: systemd-sysext unmerge failed" >&2
        exit 1
    fi
    exit 0
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
# The previous /usr upper layer and image disappear during refresh. Preserve
# owned files as bytes, not symlinks back into that layer. State is itself in the
# ephemeral /usr layer: no stale ownership survives removal or reboot.
snapshot_previous() (
    for previous_directory in "$EXPOSEDMODDIR"/* "$STATEDIR"/*; do
        [ -d "$previous_directory" ] || continue
        previous_name=$(basename "$previous_directory")
        case "$previous_name" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
        previous="$PLAN/prior/$previous_name"
        [ ! -f "$previous/paths" ] || continue
        previous_modules="$EXPOSEDMODDIR/$previous_name"
        previous_state="$STATEDIR/$previous_name"
        mkdir -p "$previous/files" || return 1
        if [ -f "$previous_state/files" ]; then
            cp "$previous_state/files" "$previous/paths" || return 1
            cp -a "$previous_state" "$previous/state" || return 1
        else
            # Migration from the earlier private-payload runtime, which exposed
            # symlinks but did not yet write an ownership journal.
            previous_payload="$PAYLOADDIR/$previous_name"
            [ -d "$previous_payload" ] || continue
            : > "$previous/paths"
            for path in "$previous_modules"/*.ko; do
                [ ! -f "$path" ] || printf '%s\n' "$path" >> "$previous/paths"
            done
            [ -s "$previous/paths" ] || continue
            for kind in firmware udev; do
                [ -d "$previous_payload/$kind" ] || continue
                find "$previous_payload/$kind" \( -type f -o -type l \) -print > "$previous/sources"
                while IFS= read -r source; do
                    relative=${source#"$previous_payload/$kind/"}
                    case "$kind" in
                        firmware) path="/usr/lib/firmware/$relative" ;;
                        udev) path="/usr/lib/udev/rules.d/$relative" ;;
                    esac
                    # Only retain resources this package actually owns.
                    [ "$(readlink -f "$path")" = "$(readlink -f "$source")" ] || continue
                    printf '%s\n' "$path" >> "$previous/paths"
                done < "$previous/sources"
            done
            mkdir -p "$previous/state" || return 1
            if [ -f "$ACTIVATIONDIR/$previous_name.conf" ]; then
                cp "$ACTIVATIONDIR/$previous_name.conf" "$previous/state/activation.conf" || return 1
            fi
            cp "$previous/paths" "$previous/state/files" || return 1
            if [ -f "$previous_payload/modules-load.conf" ]; then
                cp "$previous_payload/modules-load.conf" "$previous/state/modules-load.conf" || return 1
            fi
        fi
        while IFS= read -r path; do
            case "$path" in
                "$EXPOSEDMODDIR/$previous_name/"*|/usr/lib/firmware/*|/usr/lib/udev/rules.d/*) ;;
                *) echo "wendyos-sysext-apply: invalid prior resource path $path" >&2; return 1 ;;
            esac
            relative=${path#/usr/lib/}
            mkdir -p "$previous/files/$(dirname "$relative")" || return 1
            cp -Lp "$path" "$previous/files/$relative" || return 1
        done < "$previous/paths"
    done
)

if ! snapshot_previous; then
    echo "wendyos-sysext-apply: cannot preserve previous payloads; refusing refresh" >&2
    exit 1
fi

# --always-refresh: reinstalling a driver reuses the image filename, which on its own looks
# like no change.
if ! systemd-sysext --mutable=ephemeral --always-refresh=yes refresh; then
    echo "wendyos-sysext-apply: systemd-sysext refresh failed" >&2
    exit 1
fi

# Shared across all interfaces, packages and rollback attempts. Leave time for
# module recovery inside the agent's two-minute apply deadline.
WIFI_DEADLINE=$(($(date +%s) + 60))
CLAIMS="$PLAN/claims"
: > "$CLAIMS"

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

# Accept either a PCI bus entry or a network interface's device link. Keep
# scratch variables in a subshell so callers retain their activation state.
pci_id_of() (
    [ -f "$1/vendor" ] && [ -f "$1/device" ] || return 1
    IFS= read -r vendor < "$1/vendor" || return 1
    IFS= read -r device < "$1/device" || return 1
    printf '%s:%s' "${vendor#0x}" "${device#0x}" | tr 'A-F' 'a-f'
)

pci_device_present() {
    wanted=$1
    for device_path in /sys/bus/pci/devices/*; do
        present=$(pci_id_of "$device_path") || continue
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
        if [ -n "$owner" ] && [ "$owner" != "$package" ]; then
            echo "wendyos-sysext-apply: $package conflicts with package $owner on $claim — skipping" >&2
            return 0
        fi
    done < "$PLAN/$package.claims"
    return 1
}

reserve_claims() {
    package=$1
    next_claims="$PLAN/claims.next"
    awk -F '\t' -v package="$package" '$2 != package { print }' "$CLAIMS" > "$next_claims" || return 1
    while IFS= read -r claim; do
        printf '%s\t%s\n' "$claim" "$package" >> "$next_claims" || return 1
    done < "$PLAN/$package.claims"
    mv "$next_claims" "$CLAIMS"
}

prior_claim() {
    case "$2" in
        "$EXPOSEDMODDIR/$1/"*) printf 'module:%s\n' "$(module_sysname "$(basename "$2" .ko)")" ;;
        /usr/lib/firmware/*) printf 'firmware:%s\n' "${2#/usr/lib/firmware/}" ;;
        /usr/lib/udev/rules.d/*) printf 'udev:%s\n' "$(basename "$2")" ;;
        *) return 1 ;;
    esac
}

# A hot apply must not let a new package evict resources already in use. Keep
# the previous owners' claims until each package replaces its own exposure.
reserve_previous_claims() (
    for previous in "$PLAN/prior"/*; do
        [ -s "$previous/paths" ] || continue
        previous_name=$(basename "$previous")
        [ -e "$RUNDIR/$previous_name.raw" ] || continue
        while IFS= read -r path; do
            claim=$(prior_claim "$previous_name" "$path") || return 1
            owner=$(claim_owner "$claim")
            if [ -n "$owner" ] && [ "$owner" != "$previous_name" ]; then
                echo "wendyos-sysext-apply: prior resource $claim has multiple owners" >&2
                return 1
            fi
            [ "$owner" = "$previous_name" ] || printf '%s\t%s\n' "$claim" "$previous_name" >> "$CLAIMS" || return 1
        done < "$previous/paths"
    done
)

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

# Copy saved bytes into the mutable layer so rollback remains usable after PLAN
# cleanup. In particular, never leave a symlink pointing into a temporary backup.
restore_previous() (
    previous="$PLAN/prior/$1"
    [ -s "$previous/paths" ] || return 0
    # The previous active package still owns these resources. Do not let a later
    # candidate overwrite a restored stack just because this upgrade failed.
    while IFS= read -r path; do
        claim=$(prior_claim "$1" "$path") || return 1
        owner=$(claim_owner "$claim")
        if [ -n "$owner" ] && [ "$owner" != "$1" ]; then
            echo "wendyos-sysext-apply: cannot restore $1; $claim belongs to $owner" >&2
            return 1
        fi
        [ "$owner" = "$1" ] || printf '%s\t%s\n' "$claim" "$1" >> "$CLAIMS" || return 1
    done < "$previous/paths"
    while IFS= read -r path; do
        relative=${path#/usr/lib/}
        mkdir -p "$(dirname "$path")" || return 1
        rm -f "$path" || return 1
        cp -p "$previous/files/$relative" "$path" || return 1
    done < "$previous/paths"
    mkdir -p "$STATEDIR" || return 1
    rm -rf "${STATEDIR:?}/$1"
    cp -a "$previous/state" "$STATEDIR/$1"
)

restore_skipped_previous() {
    [ -s "$PLAN/prior/$1/paths" ] || return 0
    if ! restore_previous "$1" || ! depmod -a "$KVER"; then
        echo "wendyos-sysext-apply: could not restore previous exposure for $1; reboot required" >&2
        return 1
    fi
}

module_conf() {
    conf="$STORE/modules-load.d/$KVER/$1.conf"
    [ -f "$conf" ] || conf="$STORE/modules-load.d/any/$1.conf"
    [ -f "$conf" ] || conf="$STORE/modules-load.d/$1.conf"
    [ -f "$conf" ] || conf="$2/modules-load.conf"
}

record_active() (
    state="$STATEDIR/$name"
    mkdir -p "$state" || return 1
    cp "$PLAN/$name.exposed" "$state/files" || return 1
    if [ -f "$conf" ]; then
        cp "$conf" "$state/modules-load.conf" || return 1
    fi
    if [ -f "$activation" ]; then
        cp "$activation" "$state/activation.conf" || return 1
    fi
    cp "$removed" "$state/replaced-modules" || return 1
    # The agent compares generations to distinguish this apply from an old receipt.
    basename "$PLAN" > "$state/generation"
)

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
            # Owned payload modules were already removed by name. Repeating
            # modprobe -r could also remove a nonreplaced, preexisting dependency.
            if [ -f "$PLAN/$name.new-payload-modules" ] &&
               grep -Fqx "$(module_sysname "$mod")" "$PLAN/$name.new-payload-modules"; then
                continue
            fi
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
        # Refresh has already removed the previous add-on from the module index.
        # rmmod addresses the loaded module directly and leaves dependencies for
        # their own journalled removals; modprobe -r needs the vanished .ko file.
        [ -d "/sys/module/$sysname" ] || continue
        if ! rmmod -- "$sysname"; then
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

# 0: managed station, 1: another interface role/owner, 2: inspection failed.
# Wi-Fi device type alone also includes APs. Query the kernel's current role,
# including before reconnection when there is no active NM profile to inspect.
# Inspect that role first: NAN data interfaces may have no NM device object.
wifi_kernel_station_interface() (
    wifi_remaining=$((${2:-$WIFI_DEADLINE} - $(date +%s)))
    [ "$wifi_remaining" -gt 0 ] || return 2
    [ "$wifi_remaining" -le 5 ] || wifi_remaining=5
    wifi_info=$(timeout --kill-after=1 "$wifi_remaining" iw dev "$1" info) || return 2
    wifi_type=$(printf '%s\n' "$wifi_info" | awk '$1 == "type" { print $2 }')
    [ -n "$wifi_type" ] || return 2
    [ "$wifi_type" = managed ]
)

wifi_station_interface() (
    wifi_kernel_station_interface "$1" || return "$?"
    wifi_info=$(wifi_nmcli 5 -g GENERAL.TYPE,GENERAL.NM-MANAGED device show "$1") || return 2
    [ "$wifi_info" = "$(printf 'wifi\nyes')" ]
)

# Record physical cards even when their driver has not created an interface yet.
# Requiring each captured card avoids accepting another BE202 after hot removal
# or partial probe failure on a system with multiple cards.
capture_wifi_cards() (
    while read -r directive value extra || [ -n "${directive:-}${value:-}${extra:-}" ]; do
        [ "${directive:-}" = restore-wifi-pci ] || continue
        value=$(printf '%s' "$value" | tr 'A-F' 'a-f')
        matched=0
        for device_path in /sys/bus/pci/devices/*; do
            present=$(pci_id_of "$device_path") || continue
            [ "$present" = "$value" ] || continue
            readlink -f "$device_path" || return 1
            matched=1
        done
        if [ "$matched" = 0 ]; then
            echo "wendyos-sysext-apply: no Wi-Fi PCI device $value; refusing to unload drivers" >&2
            return 1
        fi
    done < "$1"
)

wait_wifi_cards() (
    [ -s "$1" ] || return 0
    # Share a short readiness budget across all cards and retain the outer
    # capture/reconnect deadline. Association and NM policy are not prerequisites.
    readiness_deadline=$(($(date +%s) + 10))
    [ "$readiness_deadline" -le "$WIFI_DEADLINE" ] || readiness_deadline=$WIFI_DEADLINE
    attempts=0
    while [ "$attempts" -lt 10 ] && [ "$(date +%s)" -lt "$readiness_deadline" ]; do
        missing=""
        while IFS= read -r card; do
            ready=0
            for net_path in /sys/class/net/*; do
                [ -e "$net_path/device" ] || continue
                [ "$(readlink -f "$net_path/device")" = "$card" ] || continue
                if wifi_kernel_station_interface "${net_path##*/}" "$readiness_deadline"; then
                    ready=1
                    break
                fi
            done
            [ "$ready" = 1 ] || { missing=$card; break; }
        done < "$1"
        [ -n "$missing" ] || return 0
        attempts=$((attempts+1))
        sleep 1
    done
    echo "wendyos-sysext-apply: no station interface appeared on Wi-Fi PCI card ${missing:-within readiness deadline}" >&2
    return 1
)

capture_wifi_state() {
    activation=$1
    restore_state=$2
    while read -r directive value extra || [ -n "${directive:-}${value:-}${extra:-}" ]; do
        case "${directive:-}" in
            restore-wifi-connection)
                capture_wifi_interface "$value" "$restore_state" || return 1 ;;
            restore-wifi-pci)
                value=$(printf '%s' "$value" | tr 'A-F' 'a-f')
                for net_path in /sys/class/net/*; do
                    present=$(pci_id_of "$net_path/device") || continue
                    [ "$present" = "$value" ] || continue
                    # Retain this physical card, not just its vendor/model or
                    # current wlanN name: both radios disappear during reload.
                    wifi_pci_path=$(readlink -f "$net_path/device") || return 1
                    [ -n "$wifi_pci_path" ] || return 1
                    capture_wifi_interface "${net_path##*/}" "$restore_state" "$wifi_pci_path" || return 1
                done ;;
        esac
    done < "$activation"
}

capture_wifi_interface() {
    interface=$1
    restore_state=$2
    # On a first install the new driver may create this interface. There
    # cannot be a connection to preserve if the kernel has no device yet.
    [ -e "/sys/class/net/$interface" ] || return 0
    if ! command -v nmcli >/dev/null 2>&1; then
        echo "wendyos-sysext-apply: cannot capture $interface connection: nmcli is unavailable" >&2
        return 1
    fi
    if [ -n "${3:-}" ]; then
        if wifi_station_interface "$interface"; then
            :
        else
            case "$?" in
                1) return 0 ;; # NAN, AP and other interfaces belong to their creators.
                *)
                    echo "wendyos-sysext-apply: cannot inspect $interface station role; refusing to unload its driver" >&2
                    return 1 ;;
            esac
        fi
    fi
    if ! connection_uuid=$(wifi_nmcli 5 -g GENERAL.CON-UUID device show "$interface"); then
        echo "wendyos-sysext-apply: cannot capture $interface connection; refusing to unload its driver" >&2
        return 1
    fi
    case "$connection_uuid" in
        ''|--) return 0 ;; # A successful query found no active connection.
        *[!A-Fa-f0-9-]*)
            echo "wendyos-sysext-apply: invalid connection UUID for $interface" >&2
            return 1 ;;
    esac
    if [ -n "${3:-}" ]; then
        # ifname on `connection up` selects a device; it does not override a
        # profile's name restrictions. A reload can rename this card, so reject
        # such profiles before unloading rather than rewrite the user's policy.
        if ! name_binding=$(wifi_nmcli 5 -g connection.interface-name,match.interface-name connection show uuid "$connection_uuid"); then
            echo "wendyos-sysext-apply: cannot inspect $interface profile binding; refusing to unload its driver" >&2
            return 1
        fi
        name_binding=$(printf '%s\n' "$name_binding" | sed '/^$/d; /^--$/d')
        if [ -n "$name_binding" ]; then
            echo "wendyos-sysext-apply: $interface connection $connection_uuid is restricted by interface name; PCI Wi-Fi restoration requires a profile without name restrictions; refusing to unload its driver" >&2
            return 1
        fi
        # A driver reload recreates the basic station, not arbitrary virtual
        # stations. Never collapse two saved connections onto that one target.
        while read -r prior_interface _prior_uuid prior_pci_path; do
            if [ "$prior_pci_path" = "$3" ]; then
                echo "wendyos-sysext-apply: multiple active stations on $3 ($prior_interface, $interface); refusing to unload its driver" >&2
                return 1
            fi
        done < "$restore_state"
    fi
    printf '%s %s %s\n' "$interface" "$connection_uuid" "${3:-}" >> "$restore_state" || return 1
}

wifi_interface_for_device() (
    # Run in a subshell so scanning cannot overwrite the caller's journal state.
    # Preserve the saved station name when it still belongs to this card.
    # Another card (or an AP/NAN interface) may have taken the old name.
    if [ -e "/sys/class/net/$2/device" ] &&
       [ "$(readlink -f "/sys/class/net/$2/device")" = "$1" ] &&
       wifi_station_interface "$2"; then
        printf '%s\n' "$2"
        return 0
    fi
    selected=""
    for net_path in /sys/class/net/*; do
        [ -e "$net_path/device" ] || continue
        [ "$(readlink -f "$net_path/device")" = "$1" ] || continue
        if wifi_station_interface "${net_path##*/}"; then
            :
        else
            case "$?" in
                1) continue ;;
                *) return 1 ;; # Retry when NM/kernel rediscovery is incomplete.
            esac
        fi
        # Additional NAN/AP interfaces are harmless; multiple possible stations
        # after a rename are genuinely ambiguous and must not be guessed.
        [ -z "$selected" ] || return 1
        selected=${net_path##*/}
    done
    [ -n "$selected" ] || return 1
    printf '%s\n' "$selected"
)

restore_wifi_state() {
    restore_state=$1
    [ -f "$restore_state" ] || return 1
    [ -s "$restore_state" ] || return 0
    wifi_restore_failed=0
    udevadm settle --timeout=5 >/dev/null 2>&1 || true
    while read -r interface connection_uuid wifi_pci_path; do
        [ -n "$interface" ] || continue
        saved_interface=$interface
        wifi_connected=0
        retries=0
        while [ "$retries" -lt 3 ] && [ "$(date +%s)" -lt "$WIFI_DEADLINE" ]; do
            attempts=0
            while [ "$attempts" -lt 10 ] && [ "$(date +%s)" -lt "$WIFI_DEADLINE" ]; do
                # Resolve after each rediscovery, including rollback. Never
                # reconnect an unrelated card that inherited the old name.
                if [ -n "$wifi_pci_path" ]; then
                    interface=$(wifi_interface_for_device "$wifi_pci_path" "$saved_interface") || interface=""
                    if [ -z "$interface" ]; then
                        attempts=$((attempts+1))
                        sleep 1
                        continue
                    fi
                fi
                nm_state=$(wifi_nmcli 5 -g GENERAL.STATE device show "$interface" 2>/dev/null) || nm_state=""
                case "${nm_state%% *}" in
                    30|40|50|60|70|80|90|100) break ;;
                esac
                attempts=$((attempts+1))
                sleep 1
            done
            if [ -z "$interface" ]; then
                retries=$((retries+1))
                continue
            fi
            # Service restart and NM device rediscovery are asynchronous. Retry
            # only a device that became unavailable during the activation call;
            # authentication/association failures on a ready device still fail.
            if wifi_nmcli 15 connection up uuid "$connection_uuid" ifname "$interface"; then
                wifi_connected=1
                break
            fi
            nm_state=$(wifi_nmcli 5 -g GENERAL.STATE device show "$interface" 2>/dev/null) || nm_state=""
            case "${nm_state%% *}" in ''|10|20) ;; *) break ;; esac
            retries=$((retries+1))
            sleep 1
        done
        if [ "$wifi_connected" = 0 ]; then
            echo "wendyos-sysext-apply: could not restore ${interface:-$saved_interface} connection" >&2
            wifi_restore_failed=1
        fi
    done < "$restore_state"
    [ "$wifi_restore_failed" = 0 ]
}

restart_services() (
    service_activation=$1
    [ -f "$service_activation" ] || return 0
    services_failed=0
    while read -r directive unit extra || [ -n "${directive:-}${unit:-}${extra:-}" ]; do
        [ "${directive:-}" = restart-service ] || continue
        if ! timeout --kill-after=1 15 systemctl try-restart -- "$unit"; then
            echo "wendyos-sysext-apply: could not restart $unit for $name" >&2
            services_failed=1
        fi
    done < "$service_activation"
    [ "$services_failed" = 0 ]
)

# Snapshot after old targets have been unloaded, before any candidate module
# can load. Only this payload's absent modules belong to the new transaction;
# unrelated modules and preexisting, nonreplaced modules are never collected.
capture_new_payload_modules() (
    : > "$PLAN/$name.new-payload-modules" || return 1
    while IFS= read -r claim; do
        case "$claim" in module:*) mod=${claim#module:} ;; *) continue ;; esac
        [ -d "/sys/module/$mod" ] || printf '%s\n' "$mod" >> "$PLAN/$name.new-payload-modules" || return 1
    done < "$PLAN/$name.claims"
)

# request_module_nowait waits for the helper's exec, not its exit. Once the
# producing driver is unloaded, already-started helpers remain observable here.
# Wait for all kmod aliases conservatively; never signal an unrelated process.
module_helpers_active() (
    helper_path=$(cat /proc/sys/kernel/modprobe 2>/dev/null) || return 0
    helper_name=${helper_path##*/}
    helper_name=$(printf '%s' "$helper_name" | cut -c1-15) # Linux TASK_COMM_LEN
    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        IFS= read -r comm < "$comm_file" || continue
        case "$comm" in modprobe|kmod|"$helper_name") return 0 ;; esac
    done
    return 1
)

rollback_new_payload_modules() (
    candidates="$PLAN/$name.new-payload-modules"
    [ -f "$candidates" ] || return 0 # Failure preceded candidate loading.
    attempts=0
    while [ "$attempts" -lt 10 ]; do
        pending=0
        while IFS= read -r mod; do
            [ -d "/sys/module/$mod" ] || continue
            pending=1
            held=0
            for holder in "/sys/module/$mod/holders"/*; do
                [ ! -e "$holder" ] || held=1
            done
            # Holders are removed on their own iteration only if they are also
            # transaction-owned. Never unload a foreign holder or force removal.
            [ "$held" = 0 ] || continue
            rmmod -- "$mod" || true
        done < "$candidates"
        if [ "$pending" = 0 ] && ! module_helpers_active; then
            # The last helper can finish loading between our module scan and
            # process scan. Recheck after it has exited, before restoring base.
            clean=1
            while IFS= read -r mod; do
                [ ! -d "/sys/module/$mod" ] || clean=0
            done < "$candidates"
            [ "$clean" = 1 ] && return 0
        fi
        # Candidate lookup paths are already hidden. A helper that opened a .ko
        # earlier can still finish loading it; wait for that helper and rescan.
        attempts=$((attempts+1))
        sleep 1
    done
    while IFS= read -r mod; do
        if [ -d "/sys/module/$mod" ]; then
            echo "wendyos-sysext-apply: rollback could not unload candidate module $mod" >&2
        fi
    done < "$candidates"
    if module_helpers_active; then
        echo "wendyos-sysext-apply: module helpers did not quiesce during rollback" >&2
    fi
    return 1
)

rollback_package() {
    rollback_incomplete=0
    # Close future candidate lookups first. rmmod below only needs loaded names,
    # including modules whose .ko was already opened by an asynchronous helper.
    if ! hide_payload "$PLAN/$name.exposed" || ! depmod -a "$KVER"; then
        echo "wendyos-sysext-apply: could not rebuild module index during rollback for $name" >&2
        echo "wendyos-sysext-apply: activation rollback incomplete for $name; reboot required" >&2
        return 1
    fi
    if ! rollback_new_payload_modules; then
        # A surviving backport graph cannot coexist with the base Wi-Fi ABI.
        # Restore the candidate's search paths for the surviving graph, without
        # claiming activation success or loading the old ABI underneath it.
        if ! expose_payload "$name" "$payload" || ! depmod -a "$KVER"; then
            echo "wendyos-sysext-apply: could not preserve failed candidate exposure for $name" >&2
        fi
        echo "wendyos-sysext-apply: activation rollback incomplete for $name; reboot required" >&2
        return 1
    fi
    rollback_modules "$inserted" -r || rollback_incomplete=1
    rm -rf "${STATEDIR:?}/$name" || rollback_incomplete=1
    restore_previous "$name" || rollback_incomplete=1
    if ! depmod -a "$KVER"; then
        echo "wendyos-sysext-apply: could not rebuild module index during rollback for $name" >&2
        rollback_incomplete=1
    fi
    rollback_modules "$removed" "" || rollback_incomplete=1
    udevadm control --reload >/dev/null 2>&1 || true
    # Restored devices have new kernel identities. Restart the previous payload's
    # consumers, especially supplicant, before asking NM to reconnect. A failed
    # candidate may have declared a different (or nonexistent) service.
    recovery_activation="$STATEDIR/$name/activation.conf"
    [ -f "$recovery_activation" ] || recovery_activation="$activation"
    if [ -s "$removed" ] || [ -s "$inserted" ]; then
        restart_services "$recovery_activation" || rollback_incomplete=1
    fi
    restore_wifi_state "$restore_state" || rollback_incomplete=1
    if [ "$rollback_incomplete" = 0 ]; then
        echo "wendyos-sysext-apply: activation rolled back and prior modules restored for $name" >&2
    else
        echo "wendyos-sysext-apply: activation rollback incomplete for $name; reboot required" >&2
    fi
    [ "$rollback_incomplete" = 0 ]
}

# Private payloads are not in a module search path yet. Index the base system.
# Even a failure before unloading must restore the files discarded by refresh.
if ! depmod -a "$KVER"; then
    echo "wendyos-sysext-apply: depmod failed" >&2
    for previous in "$PLAN/prior"/*; do
        [ -d "$previous" ] || continue
        restore_previous "$(basename "$previous")" || echo "wendyos-sysext-apply: could not restore previous exposure" >&2
    done
    depmod -a "$KVER" || echo "wendyos-sysext-apply: could not rebuild previous module index" >&2
    exit 1
fi

# Globs follow LC_ALL=C, making the first-wins policy stable across boots. Claims
# belong to successfully activated candidates or previously active payloads.
if ! reserve_previous_claims; then
    echo "wendyos-sysext-apply: could not reserve previous resource claims" >&2
    for previous in "$PLAN/prior"/*; do
        [ -d "$previous" ] || continue
        restore_previous "$(basename "$previous")" || echo "wendyos-sysext-apply: could not restore previous exposure" >&2
    done
    depmod -a "$KVER" || echo "wendyos-sysext-apply: could not rebuild previous module index" >&2
    exit 1
fi
rc=0
subject_seen=0
for link in "$RUNDIR"/*.raw; do
    [ -e "$link" ] || continue
    name=$(basename "$link" .raw)
    [ "$SUBJECT" != "$name" ] || subject_seen=1
    case "$name" in ''|*[!A-Za-z0-9_.-]*) echo "wendyos-sysext-apply: invalid package name '$name'" >&2; rc=1; continue ;; esac

    rel="$RELDIR/extension-release.$name"
    if [ -f "$rel" ]; then
        want=$(sed -n 's/^WENDYOS_KERNEL=//p' "$rel")
        if [ -n "$want" ] && [ "$want" != "$KVER" ]; then
            echo "wendyos-sysext-apply: $name is for kernel $want, running $KVER — skipping" >&2
            restore_skipped_previous "$name" || rc=1
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
                restore-wifi-pci)
                    case "${value:-}" in
                        ????':'????)
                            hex="${value%:*}${value#*:}"
                            case "$hex" in *[!0-9a-fA-F]*) activation_bad=1 ;; esac
                            ;;
                        *) activation_bad=1 ;;
                    esac
                    [ -z "${extra:-}" ] || activation_bad=1
                    ;;
                restart-service) [ -z "${extra:-}" ] && valid_service_name "${value:-}" || activation_bad=1 ;;
                *) activation_bad=1 ;;
            esac
        done < "$activation"
        if [ "$activation_bad" = 1 ]; then
            echo "wendyos-sysext-apply: malformed activation metadata for $name" >&2
            restore_skipped_previous "$name" || rc=1
            rc=$((rc|fail))
            continue
        fi
        if [ "$pci_declared" = 1 ] && [ "$pci_matched" = 0 ]; then
            echo "wendyos-sysext-apply: $name has no matching PCI device — skipping" >&2
            restore_skipped_previous "$name" || rc=1
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
        restore_skipped_previous "$name" || rc=1
        [ "$SUBJECT" != "$name" ] || rc=1
        continue
    fi

    activate_now=0
    if [ -z "$SUBJECT" ] || [ "$SUBJECT" = "$name" ]; then activate_now=1; fi
    removed="$PLAN/$name.removed"
    inserted="$PLAN/$name.inserted"
    restore_state="$PLAN/$name.restore"
    : > "$removed" && : > "$inserted" && : > "$restore_state" && : > "$PLAN/$name.exposed" || exit 1

    module_conf "$name" "$payload"
    if [ -f "$activation" ] && [ "$activate_now" = 1 ]; then
        if ! preflight_unload "$name" "$activation" ||
           ! capture_wifi_cards "$activation" > "$PLAN/$name.wifi-cards" ||
           ! capture_wifi_state "$activation" "$restore_state"; then
            if ! restore_previous "$name" || ! depmod -a "$KVER"; then
                echo "wendyos-sysext-apply: could not restore previous exposure for $name" >&2
            fi
            rc=$((rc|fail))
            continue
        fi
        if ! unload_targets "$name"; then
            rollback_package || true # Logs incomplete recovery; the original operation already failed.
            rc=$((rc|fail))
            continue
        fi
    fi

    if ! capture_new_payload_modules; then
        echo "wendyos-sysext-apply: could not snapshot candidate module ownership for $name" >&2
        rollback_package || true
        rc=$((rc|fail))
        continue
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
        restart_services "$activation" || package_failed=1
        if [ "$package_failed" = 0 ]; then
            wait_wifi_cards "$PLAN/$name.wifi-cards" || package_failed=1
        fi
        if [ "$package_failed" = 0 ]; then
            restore_wifi_state "$restore_state" || package_failed=1
        fi
    fi
    if [ "$package_failed" != 0 ]; then
        rollback_package || true
        rc=$((rc|fail))
        continue
    fi
    if ! record_active; then
        echo "wendyos-sysext-apply: could not record active payload for $name" >&2
        rollback_package || true
        rc=$((rc|fail))
        continue
    fi
    if ! reserve_claims "$name"; then
        echo "wendyos-sysext-apply: could not record resource claims for $name" >&2
        rollback_package || true
        rc=$((rc|fail))
        continue
    fi
done

if [ -n "$SUBJECT" ] && [ "$subject_seen" = 0 ]; then
    echo "wendyos-sysext-apply: no enabled image named '$SUBJECT' for kernel $KVER" >&2
    rc=1
fi
udevadm trigger >/dev/null 2>&1 || true
exit "$rc"
