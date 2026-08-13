#!/usr/bin/env bash
#
# Pack a driver add-on's modules into a systemd-sysext image.
#
# The payload is built directly rather than by stripping a rootfs: an image recipe would
# pull in glibc, bash and base-files through the module package's dependencies, and each
# of those would shadow the host's own copy once merged onto /usr.
#
#   pack-sysext.sh --devkit <dir> --driver <dir> --modules <dir> [--out <file.raw>]
#
set -euo pipefail

err() { echo "pack-sysext: $*" >&2; exit 1; }

DEVKIT="" DRIVER="" MODULES="" OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --devkit)  DEVKIT=$2; shift 2 ;;
        --driver)  DRIVER=$2; shift 2 ;;
        --modules) MODULES=$2; shift 2 ;;
        --out)     OUT=$2; shift 2 ;;
        -h|--help) awk 'NR>1 && /^#/{print} NR>1 && !/^#/{exit}' "$0"; exit 0 ;;
        *)         err "unknown argument: $1" ;;
    esac
done

[ -n "$DEVKIT" ]  || err "--devkit is required"
[ -n "$DRIVER" ]  || err "--driver is required"
[ -n "$MODULES" ] || err "--modules is required"
DEVKIT=$(cd "$DEVKIT" && pwd)
DRIVER=$(cd "$DRIVER" && pwd)
MODULES=$(cd "$MODULES" && pwd)

# Assigned then eval'd rather than eval'd inline: `eval "$(cmd)"` reports eval's status,
# so a failed read would look like success and leave every field empty.
read_json() {
    python3 - "$@" <<'PY'
import json, shlex, sys
doc = json.load(open(sys.argv[1]))
for spec in sys.argv[2:]:
    var, _, path = spec.partition("=")
    node = doc
    for key in path.split("."):
        node = (node or {}).get(key)
    print("%s=%s" % (var, shlex.quote(node or "")))
PY
}

devkit_vars=$(read_json "$DEVKIT/devkit.json" \
    KVER=kernel_version ARCH=arch OS_ID=os_id LEVEL=sysext_level) \
    || err "cannot read $DEVKIT/devkit.json"
eval "$devkit_vars"
driver_vars=$(read_json "$DRIVER/driver.json" NAME=name) \
    || err "cannot read $DRIVER/driver.json"
eval "$driver_vars"

[ -n "$NAME" ]  || err "driver.json has no name"
[ -n "$KVER" ]  || err "devkit.json has no kernel_version"
[ -n "$OS_ID" ] || err "devkit.json has no os_id — rebuild the devkit"
[ -n "$LEVEL" ] || err "devkit.json has no sysext_level — rebuild the devkit"

# The shipped mksquashfs stays executable but cannot run until setup.sh rewrites its ELF
# interpreter, and then fails naming the binary rather than the missing loader.
[ -f "$DEVKIT/env.sh" ] || err "devkit not initialised — run $DEVKIT/setup.sh first"

MKSQUASHFS="$DEVKIT/hosttools/mksquashfs"
[ -x "$MKSQUASHFS" ] || MKSQUASHFS=$(command -v mksquashfs) || err "no mksquashfs"
"$MKSQUASHFS" -version >/dev/null 2>&1 || err "$MKSQUASHFS will not run; re-run $DEVKIT/setup.sh"

OUT=${OUT:-$(dirname "$MODULES")/$NAME.raw}

# systemd merges an image only when its extension-release is named after the image file,
# so the two cannot be allowed to drift. Version in the directory, not the filename.
[ "$(basename "$OUT")" = "$NAME.raw" ] \
    || err "output must be named $NAME.raw to match extension-release.$NAME, got $(basename "$OUT")"

# systemd compares ARCHITECTURE against its own identifiers, which differ from the kernel's
# arch directory names for everything except arm64.
case "$ARCH" in
    arm64|arm) SD_ARCH="$ARCH" ;;
    x86)   grep -q '^CONFIG_X86_64=y' "$DEVKIT/kernel-build/.config" && SD_ARCH=x86-64 || SD_ARCH=x86 ;;
    riscv) grep -q '^CONFIG_64BIT=y'  "$DEVKIT/kernel-build/.config" && SD_ARCH=riscv64 || SD_ARCH=riscv32 ;;
    *)     err "no systemd architecture name known for kernel arch '$ARCH'" ;;
esac

# Built beside the target and moved in only on success: $OUT is often the live
# /data/extensions/enabled/<name>.raw, which a failed pack must not destroy.
TMP_OUT="$OUT.tmp.$$"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE" "$TMP_OUT"' EXIT

# --- payload -------------------------------------------------------------------------
# updates/ is the directory depmod prefers over an in-tree module of the same name. Keying
# it on $KVER means a running kernel simply does not find an add-on built for another one.
shopt -s nullglob
KOS=("$MODULES"/*.ko)
shopt -u nullglob
[ "${#KOS[@]}" -gt 0 ] || err "no .ko files in $MODULES"
install -d "$STAGE/usr/lib/modules/$KVER/updates"
install -m 0644 "${KOS[@]}" "$STAGE/usr/lib/modules/$KVER/updates/"

# Baked in so installing the add-on needs no --module flag. depmod resolves dependencies,
# so the manifest need only name the driver's top-level modules.
install -d "$STAGE/usr/lib/modules-load.d"
CONF="$STAGE/usr/lib/modules-load.d/$NAME.conf"
python3 -c '
import json, sys
for m in json.load(open(sys.argv[1])).get("modules_load", []):
    sys.stdout.write(m + "\n")' "$DRIVER/driver.json" > "$CONF"
# An add-on with nothing to autoload ships neither the file nor its directory.
[ -s "$CONF" ] || { rm -f "$CONF"; rmdir "$(dirname "$CONF")"; }

# Rules ship with the add-on: they create the device nodes with the right ownership, and
# a driver whose rules were dropped loads but behaves as though the hardware were absent.
if [ -d "$DRIVER/udev" ]; then
    install -d "$STAGE/usr/lib/udev/rules.d"
    for r in "$DRIVER"/udev/*.rules; do
        [ -e "$r" ] && install -m 0644 "$r" "$STAGE/usr/lib/udev/rules.d/"
    done
fi

# Firmware the driver requests via request_firmware().
if [ -d "$DRIVER/firmware" ]; then
    install -d "$STAGE/usr/lib/firmware"
    cp -a "$DRIVER/firmware/." "$STAGE/usr/lib/firmware/"
fi

# --- extension-release ---------------------------------------------------------------
# systemd merges X.raw only if it carries extension-release.X, matched by exact suffix.
#
# SYSEXT_LEVEL rather than VERSION_ID: systemd compares SYSEXT_LEVEL when host and add-on
# both declare one, and matching on VERSION_ID would unmerge every add-on on each OS patch.
#
# WENDYOS_KERNEL is our own field. systemd ignores unknown keys and has no kernel
# criterion, so the apply script reads it to skip an add-on built for another kernel.
install -d "$STAGE/usr/lib/extension-release.d"
cat > "$STAGE/usr/lib/extension-release.d/extension-release.$NAME" <<EOF
ID=$OS_ID
SYSEXT_LEVEL=$LEVEL
ARCHITECTURE=$SD_ARCH
EXTENSION_RELOAD_MANAGER=1
WENDYOS_KERNEL=$KVER
EOF

# --- image ---------------------------------------------------------------------------
"$MKSQUASHFS" "$STAGE" "$TMP_OUT" -comp xz -noappend -no-progress -all-root -quiet
mv -f "$TMP_OUT" "$OUT"

echo "add-on:  $NAME"
echo "kernel:  $KVER"
echo "modules: ${#KOS[@]}"
echo "image:   $OUT ($(du -h "$OUT" | cut -f1))"
