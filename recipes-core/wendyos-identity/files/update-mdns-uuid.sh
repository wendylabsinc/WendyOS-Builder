#!/bin/bash
# WendyOS mDNS identity publisher.
#
# Sets the id/name/displayname TXT records in the Avahi service file to the
# current device identity by replacing each record's VALUE in place — NOT by
# one-shot placeholder substitution, and NOT by rewriting the whole file.
#
# Why value-replacement:
#   - Idempotent + self-correcting: a value left by an earlier run (the original
#     WENDY_DEVICE_NAME placeholder, or a stale/`unknown-device` name) is matched
#     and replaced, instead of being permanently stuck once the placeholder was
#     consumed. That stuck-placeholder bug is what left mDNS advertising
#     name=unknown-device on a clean first boot.
#   - Preserves records the wendy-agent manages at RUNTIME — the service port,
#     the tls=true/false record (UpdateAvahiForProvisioning), and fqdn
#     (updateAvahiDeviceName). A from-scratch rewrite here would revert the
#     provisioned advertisement on the next reboot.
set -u

# Paths are overridable so update-mdns-uuid.test.sh can point them at a temp
# tree; on a device they always take the defaults.
UUID_FILE="${UUID_FILE:-/etc/wendyos/device-uuid}"
DEVICE_NAME_FILE="${DEVICE_NAME_FILE:-/etc/wendyos/device-name}"
# A literal hostname set at runtime by 'wendy device rename' (the agent's
# SetHostname RPC). It outranks the generated device-name here for the same
# reason it does in generate-hostname.sh: it is the name the operator chose.
#
# Without this the rename only half-survived a reboot. The hostname stuck
# (/etc/wendy-agent is bind-mounted to /data), but this publisher re-derived
# name/displayname from device-name on every boot and reverted the
# advertisement — and name/displayname are what 'wendy device list' displays.
EXPLICIT_HOSTNAME_FILE="${EXPLICIT_HOSTNAME_FILE:-/etc/wendy-agent/hostname}"
SERVICE_FILE="${SERVICE_FILE:-/etc/avahi/services/wendyos-mdns.service}"

# Wait briefly for the identity files (the generators are ordered before us, but
# stay defensive against a slow /data bind).
for i in {1..10}; do
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

# Replace a TXT record's value in place: <txt-record>KEY=...</txt-record>.
# [^<]* matches the current value up to the closing tag, so it overwrites a
# placeholder, a stale name, or a real name alike. Other records are untouched.
# The "display" prefix means the name= pattern never matches displayname=.
set_txt() {
    sed -i -E "s|(<txt-record>$1=)[^<]*|\1$2|g" "$SERVICE_FILE"
}

# Validate a literal hostname as a single DNS label. Mirrors is_valid_hostname
# in generate-hostname.sh and validHostname in the agent (services/hostname.go).
is_valid_hostname() {
    [[ "$1" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

set_txt id "$UUID"

# Self-heal a missing device name before publishing: the generator's queued
# job is lost when a failed first-boot /data mount collapses its Requires=
# chain (WDY-1888), and this publisher is the last identity step that still
# runs. generate-device-name.sh is idempotent and writes through the (by now
# retried and bound) /etc/wendyos, so this is a real name, not a junk
# fallback. Re-derive the hostname from it so the device does not keep the
# machine-id fallback hostname until the next reboot (avahi starts after us
# and picks the new hostname up).
if [ ! -s "$DEVICE_NAME_FILE" ] && [ -x /usr/bin/generate-device-name.sh ]; then
    echo "Warning: $DEVICE_NAME_FILE missing; generating it (self-heal)"
    /usr/bin/generate-device-name.sh || true
    if [ -s "$DEVICE_NAME_FILE" ] && [ -x /usr/sbin/generate-hostname.sh ]; then
        /usr/sbin/generate-hostname.sh || true
    fi
fi

# Pick the advertised name: an explicit 'wendy device rename' hostname wins and
# is used verbatim; otherwise fall back to the generated device name.
ADVERTISED_NAME=""
NAME_SOURCE=""
if [ -s "$EXPLICIT_HOSTNAME_FILE" ]; then
    EXPLICIT_NAME=$(tr -d '[:space:]' < "$EXPLICIT_HOSTNAME_FILE" | tr '[:upper:]' '[:lower:]')
    if is_valid_hostname "$EXPLICIT_NAME"; then
        ADVERTISED_NAME="$EXPLICIT_NAME"
        NAME_SOURCE="explicit hostname"
    else
        echo "Warning: $EXPLICIT_HOSTNAME_FILE is not a valid hostname label; ignoring it"
    fi
fi
if [ -z "$ADVERTISED_NAME" ] && [ -s "$DEVICE_NAME_FILE" ]; then
    ADVERTISED_NAME=$(tr -d '[:space:]' < "$DEVICE_NAME_FILE")
    NAME_SOURCE="device name"
fi

# Only set name/displayname when we actually have a name; otherwise leave
# whatever is there (placeholder or a prior good value) for a later run — never
# burn a junk fallback into the advertisement.
if [ -n "$ADVERTISED_NAME" ]; then
    DISPLAY_NAME=$(echo "$ADVERTISED_NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')
    set_txt name "$ADVERTISED_NAME"
    set_txt displayname "$DISPLAY_NAME"
    echo "Published mDNS identity: id=$UUID name=$ADVERTISED_NAME ($DISPLAY_NAME) [from $NAME_SOURCE]"
else
    echo "Warning: no device name available; left name/displayname for a later run"
fi
logger -t wendyos-identity "Published mDNS identity: id=$UUID name=${ADVERTISED_NAME:-<unset>}"

# Pick up the change if Avahi is already running. We are ordered Before=
# avahi-daemon, so it usually isn't up yet and reads the file on its own start;
# this covers the already-running case.
systemctl try-reload-or-restart avahi-daemon 2>/dev/null || true

exit 0

