# shellcheck shell=bash
# Shared identity helpers, sourced by update-mdns-uuid.sh and generate-hostname.sh
# so the name rules have one source. is_valid_hostname mirrors validHostname in
# the agent (services/hostname.go).

# A single DNS label: letter-led, 1-63 chars, no trailing hyphen.
is_valid_hostname() {
    local v="$1"
    [[ "$v" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# Read a name file: first line only, surrounding whitespace trimmed, lowercased.
# Deliberately not `tr -d [:space:]` — deleting internal whitespace or joining
# lines repairs a corrupt file into a plausible name the agent would reject.
read_name_file() {
    head -n 1 "$1" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]'
}
