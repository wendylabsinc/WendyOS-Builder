#!/usr/bin/env bash
#
# Build one driver add-on's kernel module against a kernel devkit.
#
# No build-system dependency by design: given an unpacked devkit and a driver directory
# this needs only make, tar, patch, git, curl and python3, so adding or rebuilding a driver
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
    NAME=name SRC_LOCAL=source.local SRC_GIT=source.git SRC_REV=source.rev \
    BUILD_KIND=build.kind BUILD_CONFIGURE=build.configure) \
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
case "${BUILD_KIND:-kbuild}" in
    kbuild)
        # Passed on the command line, not exported: a driver Makefile that assigns
        # KERNEL_SRC itself would override the environment but not this, so the
        # devkit always wins.
        make -C "$SRCDIR" KERNEL_SRC="$KBUILD" KERNEL_VERSION="$KVER"
        ;;
    backport-iwlwifi)
        # Intel's generated backport tree is a complete wireless subsystem, not
        # a conventional M=<dir> external module. Its public contract names the
        # prepared target tree KLIB_BUILD and requires a defconfig pass first.
        [ -n "$BUILD_CONFIGURE" ] \
            || err "build.kind backport-iwlwifi requires build.configure"
        case "$BUILD_CONFIGURE" in
            *[!A-Za-z0-9._-]*) err "unsafe build.configure target: $BUILD_CONFIGURE" ;;
        esac
        make -C "$SRCDIR" KLIB_BUILD="$KBUILD" "$BUILD_CONFIGURE"
        make -C "$SRCDIR" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" \
            KLIB_BUILD="$KBUILD" modules
        ;;
    *)
        err "unsupported build.kind: $BUILD_KIND"
        ;;
esac

mapfile -t KOS < <(find "$SRCDIR" -name '*.ko' -print)
[ "${#KOS[@]}" -gt 0 ] || err "no .ko produced"

# --- firmware -----------------------------------------------------------------------
# Large redistributable firmware blobs stay in their authoritative upstream repository.
# The manifest pins both immutable URLs and hashes; pack-sysext consumes this staged tree
# beside modules/. A malicious path must not escape the image's firmware directory.
FIRMWARE=$(python3 - "$MANIFEST" <<'PY'
import json, pathlib, re, sys
for entry in json.load(open(sys.argv[1])).get("firmware", []):
    url, digest, path = (entry.get(k, "") for k in ("url", "sha256", "path"))
    p = pathlib.PurePosixPath(path)
    if not url.startswith("https://"):
        sys.exit("firmware URL must use https: %r" % url)
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        sys.exit("firmware sha256 must be 64 lowercase hex characters: %r" % digest)
    if not path or p.is_absolute() or ".." in p.parts or path.endswith("/"):
        sys.exit("unsafe firmware path: %r" % path)
    if any("\t" in value or "\n" in value for value in (url, digest, path)):
        sys.exit("firmware fields must not contain tabs or newlines")
    print("%s\t%s\t%s" % (url, digest, path))
PY
) || err "invalid firmware entries in $MANIFEST"

if [ -n "$FIRMWARE" ]; then
    command -v curl >/dev/null || err "curl is required to fetch firmware"
    command -v sha256sum >/dev/null || err "sha256sum is required to verify firmware"
    while IFS=$'\t' read -r url digest path; do
        [ -n "$path" ] || continue
        destination="$OUT/firmware/$path"
        mkdir -p "$(dirname "$destination")"
        echo "fetching firmware $path"
        curl --fail --location --silent --show-error --retry 3 --retry-all-errors \
            --output "$destination.tmp" "$url"
        actual=$(sha256sum "$destination.tmp" | cut -d' ' -f1)
        [ "$actual" = "$digest" ] \
            || err "firmware sha256 mismatch for $path: expected $digest, got $actual"
        mv "$destination.tmp" "$destination"
    done <<< "$FIRMWARE"
fi

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
[ -z "$FIRMWARE" ] || echo "firmware: $OUT/firmware"
echo "output:  $OUT/modules"
