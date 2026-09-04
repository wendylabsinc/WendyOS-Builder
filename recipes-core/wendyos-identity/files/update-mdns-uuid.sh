#!/bin/bash
# WendyOS mDNS identity publisher. Replaces each TXT record's VALUE in place, so
# a placeholder or stale value from an earlier run is still overwritten and the
# records the agent owns at runtime (port, tls) survive untouched.
set -u

# Overridable so the test can run against a temp tree; the unit passes no
# environment on a device, so these take the defaults.
UUID_FILE="${UUID_FILE:-/etc/wendyos/device-uuid}"
DEVICE_NAME_FILE="${DEVICE_NAME_FILE:-/etc/wendyos/device-name}"
# Literal hostname from 'wendy device rename'. Outranks the generated
# device-name (as in generate-hostname.sh) so a rename survives a reboot.
EXPLICIT_HOSTNAME_FILE="${EXPLICIT_HOSTNAME_FILE:-/etc/wendy-agent/hostname}"
SERVICE_FILE="${SERVICE_FILE:-/etc/avahi/services/wendyos-mdns.service}"
GENERATE_DEVICE_NAME_SH="${GENERATE_DEVICE_NAME_SH:-/usr/bin/generate-device-name.sh}"
GENERATE_HOSTNAME_SH="${GENERATE_HOSTNAME_SH:-/usr/sbin/generate-hostname.sh}"
AVAHI_RELOAD_CMD="${AVAHI_RELOAD_CMD:-systemctl}"
IDENTITY_WAIT_SECS="${IDENTITY_WAIT_SECS:-10}"

# Shared identity helpers, one source of truth with generate-hostname.sh.
IDENTITY_LIB="${IDENTITY_LIB:-/usr/share/wendyos/identity-lib.sh}"
# shellcheck source=/dev/null
. "$IDENTITY_LIB" || { echo "Cannot source identity helpers: $IDENTITY_LIB" >&2; exit 1; }

# Wait briefly for the identity files (the generators are ordered before us, but
# stay defensive against a slow /data bind).
for _ in $(seq "$IDENTITY_WAIT_SECS"); do
    [ -f "$UUID_FILE" ] && [ -f "$DEVICE_NAME_FILE" ] && break
    sleep 1
done

if [ ! -f "$SERVICE_FILE" ]; then
    echo "Avahi service file $SERVICE_FILE not found; nothing to publish"
    exit 0
fi

# Self-heal the UUID if the generator didn't produce it (ordered before us, after
# the /data bind, so this lands on persistent /data).
if [ ! -f "$UUID_FILE" ]; then
    echo "Warning: $UUID_FILE missing; generating one (self-heal)"
    mkdir -p "$(dirname "$UUID_FILE")"
    uuidgen | tr '[:upper:]' '[:lower:]' > "$UUID_FILE"
    chmod 644 "$UUID_FILE"
fi
UUID=$(tr -d '[:space:]' < "$UUID_FILE")

# Replace a TXT record's value in place. [^<]* stops at the closing tag, so a
# placeholder or stale value is overwritten; the leading "display" keeps a name=
# match from also hitting displayname=.
set_txt() {
    sed -i -E "s|(<txt-record>$1=)[^<]*|\1$2|g" "$SERVICE_FILE"
}

# "brave-dolphin" -> "Brave Dolphin". Keeps empty segments from consecutive
# hyphens so it matches the agent's avahiDisplayName (else avahi keeps restarting).
display_name() {
    local -a words
    IFS='-' read -r -a words <<< "$1"
    local i
    for i in "${!words[@]}"; do words[i]="${words[i]^}"; done
    local IFS=' '
    printf '%s' "${words[*]}"
}

set_txt id "$UUID"

# Self-heal a missing device-name (last identity step to run): a failed
# first-boot /data mount can drop the generator's job. Re-derive the hostname too.
if [ ! -s "$DEVICE_NAME_FILE" ] && [ -x "$GENERATE_DEVICE_NAME_SH" ]; then
    echo "Warning: $DEVICE_NAME_FILE missing; generating it (self-heal)"
    "$GENERATE_DEVICE_NAME_SH" || true
    if [ -s "$DEVICE_NAME_FILE" ] && [ -x "$GENERATE_HOSTNAME_SH" ]; then
        "$GENERATE_HOSTNAME_SH" || true
    fi
fi

# Pick the advertised name: an explicit 'wendy device rename' wins, else the
# generated device-name. Validate each before use — the value goes into a sed
# replacement and into XML, where '&', '|' or '<' would corrupt the file.
ADVERTISED_NAME=""
NAME_SOURCE=""
if [ -s "$EXPLICIT_HOSTNAME_FILE" ]; then
    # No bind mount means /data did not mount and this is the rootfs copy
    # setup-etc-binds.sh leaves behind — still authoritative, so note it.
    EXPLICIT_HOSTNAME_DIR=$(dirname "$EXPLICIT_HOSTNAME_FILE")
    if command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "$EXPLICIT_HOSTNAME_DIR"; then
        echo "Note: $EXPLICIT_HOSTNAME_DIR is not a bind mount; using the rootfs copy"
    fi
    EXPLICIT_NAME=$(read_name_file "$EXPLICIT_HOSTNAME_FILE")
    if is_valid_hostname "$EXPLICIT_NAME"; then
        ADVERTISED_NAME="$EXPLICIT_NAME"
        NAME_SOURCE="explicit hostname"
    else
        echo "Warning: $EXPLICIT_HOSTNAME_FILE is not a valid hostname label; ignoring it"
    fi
fi
if [ -z "$ADVERTISED_NAME" ] && [ -s "$DEVICE_NAME_FILE" ]; then
    DEVICE_NAME=$(read_name_file "$DEVICE_NAME_FILE")
    if is_valid_hostname "$DEVICE_NAME"; then
        ADVERTISED_NAME="$DEVICE_NAME"
        NAME_SOURCE="device name"
    else
        echo "Warning: device-name '$DEVICE_NAME' is not a valid hostname label; ignoring it"
    fi
fi

# Only set the name records when we actually have a name; otherwise leave
# whatever is there (placeholder or a prior good value) for a later run — never
# burn a junk fallback into the advertisement.
if [ -n "$ADVERTISED_NAME" ]; then
    DISPLAY_NAME=$(display_name "$ADVERTISED_NAME")
    set_txt name "$ADVERTISED_NAME"
    set_txt displayname "$DISPLAY_NAME"
    echo "Published mDNS identity: id=$UUID name=$ADVERTISED_NAME ($DISPLAY_NAME) [from $NAME_SOURCE]"
else
    echo "Warning: no device name available; left name/displayname for a later run"
fi
logger -t wendyos-identity \
    "Published mDNS identity: id=$UUID name=${ADVERTISED_NAME:-<unset>} source=${NAME_SOURCE:-none}" \
    2>/dev/null || true

# Pick up the change if Avahi is already running. We are ordered Before=
# avahi-daemon, so it usually isn't up yet and reads the file on its own start;
# this covers the already-running case.
"$AVAHI_RELOAD_CMD" try-reload-or-restart avahi-daemon 2>/dev/null || true

exit 0
