#!/usr/bin/env bash
#
# Build one driver add-on's kernel module against a kernel devkit.
#
# No build-system dependency by design: given an unpacked devkit and a driver directory
# this needs only make, tar, patch, git and python3, so adding or rebuilding a driver
# never requires a kernel build.
#
#   build-driver.sh --devkit <dir> --driver <dir> [--out <dir>] [--sign-key <pem>]
#
set -euo pipefail

err() { echo "build-driver: $*" >&2; exit 1; }

DEVKIT="" DRIVER="" OUT="" SIGN_KEY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --devkit)   DEVKIT=$2; shift 2 ;;
        --driver)   DRIVER=$2; shift 2 ;;
        --out)      OUT=$2; shift 2 ;;
        --sign-key) SIGN_KEY=$2; shift 2 ;;
        -h|--help)  awk 'NR>1 && /^#/{print} NR>1 && !/^#/{exit}' "$0"; exit 0 ;;
        *)          err "unknown argument: $1" ;;
    esac
done

[ -n "$DEVKIT" ] || err "--devkit is required"
[ -n "$DRIVER" ] || err "--driver is required"
DEVKIT=$(cd "$DEVKIT" && pwd)
DRIVER=$(cd "$DRIVER" && pwd)
OUT=${OUT:-$DRIVER/build}

MANIFEST="$DRIVER/driver.json"
[ -f "$MANIFEST" ] || err "no driver.json in $DRIVER"
[ -f "$DEVKIT/devkit.json" ] || err "no devkit.json in $DEVKIT; is it unpacked?"

# python3 rather than jq: the devkit's relocation step already requires it.
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

# Assigned then eval'd rather than eval'd inline: `eval "$(cmd)"` reports eval's status,
# so a failed read would look like success and leave every field empty.
devkit_vars=$(read_json "$DEVKIT/devkit.json" \
    KVER=kernel_version ARCH=arch CROSS=cross_compile TC_BINDIR=toolchain_bindir) \
    || err "cannot read $DEVKIT/devkit.json"
eval "$devkit_vars"

KBUILD="$DEVKIT/kernel-build"
TC_BIN="$DEVKIT/$TC_BINDIR"
[ -n "$KVER" ] || err "devkit.json has no kernel_version — rebuild the devkit"
[ -x "$TC_BIN/${CROSS}gcc" ] || err "no cross gcc at $TC_BIN/${CROSS}gcc"

# Prefer the devkit's own binutils, so the runner needs no host strings.
STRINGS="$TC_BIN/${CROSS}strings"
[ -x "$STRINGS" ] || STRINGS=$(command -v strings) || err "no strings tool available"

# Without setup.sh the toolchain fails with a bare "No such file or directory" naming the
# binary rather than the missing loader.
[ -f "$DEVKIT/env.sh" ] || err "devkit not initialised — run $DEVKIT/setup.sh first"
# shellcheck source=/dev/null
. "$DEVKIT/env.sh"

"$TC_BIN/${CROSS}gcc" --version >/dev/null 2>&1 \
    || err "cross gcc will not start even after sourcing env.sh; re-run $DEVKIT/setup.sh"

# --- source -------------------------------------------------------------------------
# `local` builds the directory in place, `git` clones a pinned revision; anything else is
# rejected rather than guessed at.
driver_vars=$(read_json "$MANIFEST" \
    NAME=name SRC_LOCAL=source.local SRC_GIT=source.git SRC_REV=source.rev) \
    || err "cannot read $MANIFEST"
eval "$driver_vars"
[ -n "$NAME" ] || err "driver.json has no name"

rm -rf "$OUT"; mkdir -p "$OUT"
SRCDIR="$OUT/src"
if [ -n "$SRC_LOCAL" ]; then
    mkdir -p "$SRCDIR"
    # Anchored with ./: bare --exclude=build is unanchored and would also drop a nested
    # tools/build/ that the driver needs to compile.
    tar -cf - -C "$DRIVER/$SRC_LOCAL" --exclude=./build --exclude=./driver.json . \
        | tar -xf - -C "$SRCDIR"
elif [ -n "$SRC_GIT" ]; then
    [ -n "$SRC_REV" ] || err "source.git needs a pinned source.rev"
    git clone --quiet "$SRC_GIT" "$SRCDIR"
    git -C "$SRCDIR" checkout --quiet "$SRC_REV"
else
    err "driver.json source must set either 'local' or 'git'"
fi

# Out-of-tree modules break on internal API changes, so patches are gated on kernel
# version. An unparseable constraint is an error, not a silently skipped patch.
PATCHES=$(python3 - "$MANIFEST" "$KVER" <<'PY'
import json, re, sys
manifest, kver = sys.argv[1], sys.argv[2]

def parts(s):
    return tuple(int(x) for x in re.findall(r"\d+", s)[:3])

def applies(spec):
    if not spec:
        return True
    m = re.match(r"^\s*(>=|<=|>|<|==)?\s*([0-9.]+)\s*$", spec)
    if not m:
        sys.exit("unparseable kernel constraint: %r" % spec)
    op, want = m.group(1) or "==", parts(m.group(2))
    have = parts(kver)[: len(want)]
    return {">=": have >= want, "<=": have <= want, ">": have > want,
            "<": have < want, "==": have == want}[op]

for entry in json.load(open(manifest)).get("patches", []):
    if applies(entry.get("kernel")):
        print(entry["file"])
PY
)
# Read line by line: unquoted expansion would split a filename containing a space into
# two nonexistent patches and glob-expand any wildcard in it.
while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "applying $p"
    patch -d "$SRCDIR" -p1 < "$DRIVER/patches/$p" || err "patch failed: $p"
done <<< "$PATCHES"

# --- build --------------------------------------------------------------------------
export ARCH CROSS_COMPILE="$CROSS"
export PATH="$TC_BIN:$PATH"

echo "building $NAME against $KVER ($ARCH, $CROSS)"
# Passed on the command line, not exported: a driver Makefile that assigns KERNEL_SRC
# itself would override the environment but not this, so the devkit always wins.
make -C "$SRCDIR" KERNEL_SRC="$KBUILD" KERNEL_VERSION="$KVER"

mapfile -t KOS < <(find "$SRCDIR" -name '*.ko' -print)
[ "${#KOS[@]}" -gt 0 ] || err "no .ko produced"

# insmod rejects a vermagic that does not match the devkit's uname -r, so catch it here
# rather than on a device. `|| true`: head's early exit SIGPIPEs strings, which pipefail
# would otherwise turn into a fatal error on a valid module.
VERMAGIC=$("$STRINGS" "${KOS[0]}" | sed -n 's/^vermagic=//p' | head -1 || true)
case "$VERMAGIC" in
    # Without modversions the Module.symvers CRCs are absent and insmod rejects the module.
    "$KVER "*modversions*) echo "vermagic: $VERMAGIC" ;;
    "$KVER "*) err "module built without modversions; check Module.symvers in the devkit" ;;
    "")        err "no vermagic in $(basename "${KOS[0]}") — the module would not load" ;;
    *)         err "vermagic mismatch: module says '$VERMAGIC', devkit says '$KVER'" ;;
esac

# --- sign ---------------------------------------------------------------------------
# Signing while enforcement is off keeps enabling MODULE_SIG_FORCE later a kernel-config
# change rather than a pipeline change.
if [ -n "$SIGN_KEY" ]; then
    SIGN_TOOL="$KBUILD/scripts/sign-file"
    CERT="$DEVKIT/certs/signing_key.x509"
    [ -x "$SIGN_TOOL" ] || err "no sign-file in the devkit"
    [ -f "$CERT" ] || err "no signing certificate in the devkit"
    for ko in "${KOS[@]}"; do
        # sign-file reports a key/certificate mismatch as raw openssl internals, so the
        # error below names the usual cause instead.
        "$SIGN_TOOL" sha256 "$SIGN_KEY" "$CERT" "$ko" \
            || err "sign-file failed on $(basename "$ko"); on a key/certificate mismatch the devkit is stale — rebuild it for the kernel this key belongs to"
        echo "signed $(basename "$ko")"
    done
else
    echo "NOT SIGNED (no --sign-key): loads while MODULE_SIG_FORCE is off, rejected once it is on"
fi

mkdir -p "$OUT/modules"
cp "${KOS[@]}" "$OUT/modules/"

echo
echo "driver:  $NAME"
echo "kernel:  $KVER"
echo "modules: ${KOS[*]##*/}"
echo "output:  $OUT/modules"
