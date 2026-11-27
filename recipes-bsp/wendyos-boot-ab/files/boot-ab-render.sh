#!/bin/sh
# Render a WendyOS A/B boot script: the shared slot-selection head followed by a
# board family's boot tail, with every @@NAME@@ replaced by its value.
#
# Usage: boot-ab-render.sh HEAD TAIL OUT NAME=VALUE...
# Values must not contain '|', '&' or '\' (sed replacement syntax).
set -eu

[ "$#" -ge 3 ] || { echo "usage: $0 HEAD TAIL OUT NAME=VALUE..." >&2; exit 2; }
head=$1
tail=$2
out=$3
shift 3

cat "$head" "$tail" > "$out.tmp"
for pair in "$@"; do
    name=${pair%%=*}
    value=${pair#*=}
    case $value in
        *'|'* | *'&'* | *"\\"*)
            printf 'boot-ab-render: %s has a character sed cannot take: %s\n' "$name" "$value" >&2
            exit 1 ;;
    esac
    sed -i "s|@@${name}@@|${value}|g" "$out.tmp"
done

# An unresolved placeholder would reach U-Boot as literal text.
if grep -n '@@[A-Za-z0-9_]*@@' "$out.tmp" >&2; then
    echo "boot-ab-render: unresolved placeholders above" >&2
    rm -f "$out.tmp"
    exit 1
fi
mv "$out.tmp" "$out"
