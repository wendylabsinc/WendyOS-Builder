#!/bin/sh

set -eu

TARGET_ROOT="${1:-/tgt_root}"
CONNECTION_DIR="${TARGET_ROOT}/etc/NetworkManager/system-connections"
CONNECTION_FILE="${CONNECTION_DIR}/wendyos-install-wifi.nmconnection"

read_answer() {
    prompt="$1"
    var_name="$2"

    printf "%s" "$prompt"
    IFS= read -r answer || answer=""
    eval "$var_name=\$answer"
}

read_secret() {
    prompt="$1"
    var_name="$2"

    printf "%s" "$prompt"
    if stty -echo 2>/dev/null; then
        IFS= read -r answer || answer=""
        stty echo 2>/dev/null || true
        printf "\n"
    else
        IFS= read -r answer || answer=""
    fi
    eval "$var_name=\$answer"
}

random_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        echo "00000000-0000-4000-8000-000000000001"
    fi
}

write_wifi_profile() {
    ssid="$1"
    key_mgmt="$2"
    identity="${3:-}"
    password="${4:-}"
    uuid="$(random_uuid)"

    mkdir -p "$CONNECTION_DIR"
    umask 077

    {
        echo "[connection]"
        echo "id=WendyOS Wi-Fi"
        echo "uuid=${uuid}"
        echo "type=wifi"
        echo "autoconnect=true"
        echo
        echo "[wifi]"
        echo "mode=infrastructure"
        echo "ssid=${ssid}"
        echo
        echo "[wifi-security]"
        echo "key-mgmt=${key_mgmt}"
        if [ "$key_mgmt" = "wpa-psk" ]; then
            echo "psk=${password}"
        fi
        if [ "$key_mgmt" = "wpa-eap" ]; then
            echo
            echo "[802-1x]"
            echo "eap=peap;"
            echo "identity=${identity}"
            echo "password=${password}"
            echo "phase2-auth=mschapv2"
        fi
        echo
        echo "[ipv4]"
        echo "method=auto"
        echo
        echo "[ipv6]"
        echo "addr-gen-mode=default"
        echo "method=auto"
    } > "$CONNECTION_FILE"

    chmod 0600 "$CONNECTION_FILE"
}

echo
read_answer "Configure Wi-Fi for first boot? [y/N]: " configure_wifi
case "$configure_wifi" in
    y|Y|yes|YES)
        ;;
    *)
        echo "Skipping Wi-Fi configuration."
        exit 0
        ;;
esac

read_answer "Wi-Fi SSID: " wifi_ssid
if [ -z "$wifi_ssid" ]; then
    echo "No SSID entered; skipping Wi-Fi configuration."
    exit 0
fi

echo "Security type:"
echo "  1) WPA/WPA2/WPA3 personal password"
echo "  2) WPA Enterprise username/password (PEAP/MSCHAPv2)"
read_answer "Select [1]: " security_choice

case "$security_choice" in
    2)
        read_answer "Wi-Fi username/identity: " wifi_identity
        read_secret "Wi-Fi password: " wifi_password
        if [ -z "$wifi_identity" ] || [ -z "$wifi_password" ]; then
            echo "Missing username or password; skipping Wi-Fi configuration."
            exit 0
        fi
        write_wifi_profile "$wifi_ssid" "wpa-eap" "$wifi_identity" "$wifi_password"
        ;;
    *)
        read_secret "Wi-Fi password: " wifi_password
        if [ -z "$wifi_password" ]; then
            echo "No password entered; skipping Wi-Fi configuration."
            exit 0
        fi
        write_wifi_profile "$wifi_ssid" "wpa-psk" "" "$wifi_password"
        ;;
esac

echo "Wrote Wi-Fi configuration to installed system."
