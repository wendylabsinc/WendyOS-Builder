#!/usr/bin/env bash
# Produce a Jetson AGX Thor (T264) "flashpack" from an extracted WendyOS
# jetson-agx-thor tegraflash bundle.
#
# The flashpack is the single, self-describing artifact the wendy CLI downloads,
# extracts and flashes from a Mac or Linux host. All of the offline (no-device)
# work that NVIDIA's initrd-flash would do — signing the partition images and
# generating the RCM-boot chain — happens here on the x86_64 builder, so the host
# only has to: download, extract, run. (The NVIDIA flash tools are i386/x86-64 and
# do not run on macOS arm64; nothing in the flashpack is an executable.)
#
# This mirrors initrd-flash's T264 branch (prepare_binaries_t264 +
# create_l4t_bsp_images.py) but stops before it touches USB — the RCM boot and the
# ADB partition flash are what the host does against the device.
#
# Usage:
#   make-thor-flashpack.sh --bundle-dir <extracted-tar> --out <dir> --version <ver>
#                          [--board jetson-t264]
#
#   --bundle-dir  a directory holding an extracted *.tegraflash-tar (contains
#                 initrd-flash, tegra264-flash-helper.sh, boardvars.sh, the .simg,
#                 unified_flash/, create_l4t_bsp_images.py, ...). MUTATED in place
#                 (gets out/, rcmboot_blob/, bootloader/), so pass a scratch copy.
#   --out         where the flashpack/ tree and the .tar are written.
#   --version     WendyOS version string recorded in the manifest (e.g. 0.16.0 or
#                 nightly-20260629T...). Names the output tar.
#
# Output:
#   <out>/flashpack/                                          the assembled tree
#   <out>/wendyos-<version>-jetson-agx-thor.flashpack.tar.zst  the artifact CI uploads
set -euo pipefail

err() { echo "ERR: $*" >&2; exit 1; }
log() { echo "== $* =="; }
sha256() { shasum -a256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

# Pure-python PyYAML for bootburn's `import yaml`, fetched from PyPI (pinned +
# hash-verified) and shipped in the flashpack with its LICENSE.
PYYAML_VERSION="6.0.2"
PYYAML_SDIST_URL="https://files.pythonhosted.org/packages/54/ed/79a089b6be93607fa5cdaedf301d7dfb23af5f25c398d5ead2525b063e17/pyyaml-6.0.2.tar.gz"
PYYAML_SDIST_SHA256="d584d9ec91ad65861cc08d42e834324ef890a082e591037abe114850ff7bbc3e"

BUNDLE_DIR="" OUT="" VERSION="" BOARD="jetson-t264"
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle-dir) BUNDLE_DIR="$2"; shift 2;;
        --out)        OUT="$2"; shift 2;;
        --version)    VERSION="$2"; shift 2;;
        --board)      BOARD="$2"; shift 2;;
        -h|--help)    awk 'NR>1 && /^#/{print} NR>1 && !/^#/{exit}' "$0"; exit 0;;
        *) err "unknown arg: $1";;
    esac
done
[ -n "$BUNDLE_DIR" ] || err "--bundle-dir is required"
[ -n "$OUT" ]        || err "--out is required"
[ -n "$VERSION" ]    || err "--version is required"

here="$(cd "$BUNDLE_DIR" && pwd)"
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"
cd "$here"
[ -f .env.initrd-flash ] || err "$here is not an extracted tegraflash bundle (.env.initrd-flash missing)"

# .env.initrd-flash assigns into an associative array (DEFAULTS[...]); declare it so
# those assignments have a target, and relax nounset only while sourcing the bundle's
# own env files (which only exist at runtime, so shellcheck can't follow them).
# shellcheck disable=SC2034  # populated by the sourced env, not read here
declare -A DEFAULTS
[ -f boardvars.sh ] || err "boardvars.sh missing (needed for headless, no-device generation)"
set +u
# shellcheck disable=SC1091
. ./.env.initrd-flash
# shellcheck disable=SC1091
. ./boardvars.sh
set -u

# Inputs prepare_binaries_t264 reads via eval (invisible to the linter): empty
# keyfile/sbk_keyfile pick the ODM-open zero-key signing path, empty instance_args is
# headless (no --usb-instance). Must be set or set -u trips inside the function.
# shellcheck disable=SC2034
keyfile="" sbk_keyfile="" datafile="${DATAFILE:-}" serial_number="" instance_args="" PRESIGNED=""
: "${EXTERNAL_ROOTFS_DRIVE:=1}"
FLASH_HELPER="${FLASH_HELPER:-tegra264-flash-helper.sh}"
logfile="$here/make-thor-flashpack.log"
: > "$logfile"

# Reuse initrd-flash's own functions verbatim (definitions only — sourcing the
# whole script would run its device-waiting main flow). If a future BSP renames
# these, this extraction is where it breaks, loudly.
for fn in prepare_binaries_t264 stage_files_for_uniflash update_flash_cfg_for_partition; do
    body="$(awk -v f="^$fn\\\\(\\\\)" '$0 ~ f {g=1} g{print} g&&/^}/{exit}' initrd-flash)"
    [ -n "$body" ] || err "could not extract $fn() from initrd-flash"
    eval "$body"
done

# ---------------------------------------------------------------------------
log "Step 1: prepare signed partition images (no device)"
# ---------------------------------------------------------------------------
prepare_binaries_t264 internal flash.xml.in "$LNXFILE" "$ROOTFS_IMAGE" "$datafile" \
    2>&1 | tee -a "$logfile" || err "prepare internal failed"
if [ -e external-flash.xml.in ]; then
    prepare_binaries_t264 external external-flash.xml.in "$LNXFILE" "$ROOTFS_IMAGE" "$datafile" \
        2>&1 | tee -a "$logfile" || err "prepare external failed"
fi
prepare_binaries_t264 rcm-boot rcmboot-flash.xml.in initrd-flash.img "$ROOTFS_IMAGE" "$datafile" \
    2>&1 | tee -a "$logfile" || err "prepare rcm-boot failed"

# ---------------------------------------------------------------------------
log "Step 2: assemble unified flash workspace"
# ---------------------------------------------------------------------------
export CHIP_SKU
convargs=(--profile base)
if [ "$EXTERNAL_ROOTFS_DRIVE" = 1 ]; then
    convargs+=(--external-device "$ROOTFS_DEVICE" external-secureflash.xml)
fi
rm -rf out && mkdir out
./unified_flash/tools/flashtools/bootburn/create_bsp_images.py -b "$BOARD" --toolsonly -l -g "$PWD/out" --l4t \
    2>&1 | tee -a "$logfile"
mkdir -p out/flash_workspace/flash-images
# Only flash-images/ is flashed at stage 2 (FlashImages reads nothing else); the
# rcm-boot/rcm-flash workspace dirs are the host's own boot phase, which the wendy
# CLI does itself from stage1/, so we never generate them.
./create_l4t_bsp_images.py "${convargs[@]}" --info --dest "$PWD/out"                       2>&1 | tee -a "$logfile"
./create_l4t_bsp_images.py "${convargs[@]}" --dest "$PWD/out/flash_workspace/flash-images" 2>&1 | tee -a "$logfile"

# ---------------------------------------------------------------------------
log "Step 3: assemble flashpack tree"
# ---------------------------------------------------------------------------
FP="$OUT/flashpack"
rm -rf "$FP"
mkdir -p "$FP/stage1" "$FP/stage2"

# stage1 — the RCM-boot images the host sends verbatim (rcmboot_blob outputs).
S1_FIXED=(br_bct_BR.bct
          mb1_t264_prod_aligned_sigheader.bin.encrypt
          psc_bl1_t264_prod_aligned_sigheader.bin.encrypt
          mb1_bct_MB1_sigheader.bct.encrypt
          blob.bin)
for f in "${S1_FIXED[@]}"; do
    [ -f "rcmboot_blob/$f" ] || err "stage1 artifact missing: rcmboot_blob/$f"
    cp "rcmboot_blob/$f" "$FP/stage1/"
done
# all 8 membct (host picks by on-board RAMCODE/2; tiny)
cp rcmboot_blob/membct_*_sigheader.bct.encrypt "$FP/stage1/" || err "no membct in rcmboot_blob"

# stage2/out — the generated workspace + its sibling tools/ (bootburn reads
# flash_workspace/../tools).
cp -R out "$FP/stage2/out"

# stage2/bundle — NVIDIA's bootburn scripts the stage-2 flasher drives. Trim the
# boot-phase flashing kernel (host RCM-boots itself), pycache, and the dead x86 adb
# (the host injects its own static adb shim).
mkdir -p "$FP/stage2/bundle/unified_flash/tools"
cp -R unified_flash/tools/flashtools "$FP/stage2/bundle/unified_flash/tools/"
[ -f unified_flash/version-nv-sdk.txt ] && cp unified_flash/version-nv-sdk.txt "$FP/stage2/bundle/unified_flash/"
rm -rf "$FP/stage2/bundle/unified_flash/tools/flashtools/flashing_kernel"
find "$FP/stage2" -depth -name __pycache__ -type d -exec rm -rf {} +
# Drop binaries the host never uses (it injects its own static adb shim; Windows
# .exe/.dll never apply), keeping the artifact OS-neutral.
find "$FP/stage2" -type f \( -name adb -o -name 'adb.exe' -o -name '*.exe' -o -name '*.dll' \) -delete 2>/dev/null || true

# stage2/pyyaml — the pure-python lib/yaml package + LICENSE (no C-ext shim); the
# host puts this dir on PYTHONPATH at flash time.
PYDIR="$FP/stage2/pyyaml"
mkdir -p "$PYDIR"
pytmp="$(mktemp -d)"
curl -fsSL "$PYYAML_SDIST_URL" -o "$pytmp/pyyaml.tar.gz" || err "downloading PyYAML sdist failed"
got="$(sha256 "$pytmp/pyyaml.tar.gz")"
[ "$got" = "$PYYAML_SDIST_SHA256" ] || err "PyYAML sdist sha256 mismatch (got $got, want $PYYAML_SDIST_SHA256)"
tar -C "$pytmp" -xzf "$pytmp/pyyaml.tar.gz"
pysrc="$pytmp/pyyaml-$PYYAML_VERSION"
[ -d "$pysrc/lib/yaml" ] || err "PyYAML sdist layout changed: lib/yaml not found"
[ -f "$pysrc/LICENSE" ]  || err "PyYAML sdist has no LICENSE"
cp -R "$pysrc/lib/yaml" "$PYDIR/yaml"
cp "$pysrc/LICENSE" "$PYDIR/LICENSE"
find "$PYDIR" -depth -name __pycache__ -type d -exec rm -rf {} +
rm -rf "$pytmp"
echo "  pyyaml: $PYYAML_VERSION (+ LICENSE)"

# ---------------------------------------------------------------------------
log "Step 4: validate"
# ---------------------------------------------------------------------------
magic() { head -c4 "$1" | tr -d '\0'; }
[ "$(magic "$FP/stage1/br_bct_BR.bct")" = "BCTB" ] || err "br_bct_BR.bct: bad magic (expected BCTB)"
for f in mb1_t264_prod_aligned_sigheader.bin.encrypt \
         psc_bl1_t264_prod_aligned_sigheader.bin.encrypt \
         mb1_bct_MB1_sigheader.bct.encrypt; do
    [ "$(magic "$FP/stage1/$f")" = "NVDA" ] || err "$f: bad magic (expected NVDA)"
done
[ -s "$FP/stage1/blob.bin" ] || err "blob.bin is empty"

FTF="$FP/stage2/out/flash_workspace/flash-images/FileToFlash.txt"
[ -f "$FTF" ] || err "FileToFlash.txt missing in flash-images"
missing=0
while IFS=, read -r _num _loc _start _size partfile _rest; do
    partfile="$(echo "$partfile" | tr -d '[:space:]')"
    [ -n "$partfile" ] || continue
    case "$partfile" in \#*) continue;; esac
    if [ ! -f "$FP/stage2/out/flash_workspace/flash-images/$partfile" ]; then
        echo "  MISSING: $partfile" >&2; missing=$((missing+1))
    fi
done < <(grep -vE '^\s*#' "$FTF")
[ "$missing" = 0 ] || err "$missing partition file(s) referenced by FileToFlash.txt are missing"
echo "  FileToFlash.txt: all referenced files present"

[ -f "$FP/stage2/pyyaml/yaml/__init__.py" ] || err "stage2/pyyaml/yaml package missing"
[ -f "$FP/stage2/pyyaml/LICENSE" ]           || err "stage2/pyyaml/LICENSE missing"

# ---------------------------------------------------------------------------
log "Step 5: write manifest.json"
# ---------------------------------------------------------------------------
DEFAULT_MEMBCT="membct_$(( ${RAMCODE:-12} / 2 ))_sigheader.bct.encrypt"
[ -f "$FP/stage1/$DEFAULT_MEMBCT" ] || err "computed default membct missing: $DEFAULT_MEMBCT"
# The manifest schema is defined authoritatively by the Go consumer
# (go/internal/cli/tegraflash/flashpack/flashpack.go: type Manifest). Keep these
# fields in sync with it. Only stage-1 files get integrity hashes: stage-2 images
# are verified device-side by bootburn (its FileToFlash.txt MD5 column), and the
# tarball as a whole is checksummed on download.
VERSION="$VERSION" RAMCODE="${RAMCODE:-}" CHIP_SKU="${CHIP_SKU:-}" \
    PYYAML_VERSION="$PYYAML_VERSION" DEFAULT_MEMBCT="$DEFAULT_MEMBCT" FP="$FP" \
    python3 - <<'PY'
import os, json, hashlib, pathlib
fp = pathlib.Path(os.environ["FP"])
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()
stage1 = fp / "stage1"
files = {}
for p in sorted(stage1.rglob("*")):
    if p.is_file():
        rel = str(p.relative_to(fp))
        files[rel] = {"sha256": sha(p), "size": p.stat().st_size}
m = {
    "schema": 1,
    "wendyos_version": os.environ["VERSION"],
    "default_membct": os.environ["DEFAULT_MEMBCT"],
    "stage1_send_order": [
        "br_bct_BR.bct",
        "mb1_t264_prod_aligned_sigheader.bin.encrypt",
        "psc_bl1_t264_prod_aligned_sigheader.bin.encrypt",
        "mb1_bct_MB1_sigheader.bct.encrypt",
    ],
    "layout": {
        "stage1": "stage1",
        "flash_workspace": "stage2/out/flash_workspace",
    },
    "files": files,
    # provenance only (not read by wendy)
    "board": "jetson-agx-thor",
    "machine": "jetson-agx-thor-devkit-nvme-wendyos",
    "chip": "0x26",
    "ramcode": os.environ.get("RAMCODE") or None,
    "chip_sku": os.environ.get("CHIP_SKU") or None,
    "pyyaml_version": os.environ.get("PYYAML_VERSION") or None,
}
(fp / "manifest.json").write_text(json.dumps(m, indent=2) + "\n")
print(f"  manifest: {len(files)} stage-1 files hashed")
PY

# ---------------------------------------------------------------------------
log "Step 6: pack (.tar.zst — what the wendy CLI downloads and extracts)"
# ---------------------------------------------------------------------------
TAR_ZST="$OUT/wendyos-${VERSION}-jetson-agx-thor.flashpack.tar.zst"
# Stream tar straight into zstd so we never write the ~6.6 GB uncompressed tar.
# -19 --long=27 -T0: high ratio (the rootfs .simg + mostly-zero config/esp images
# compress well), multi-threaded; tune ZSTD_LEVEL if build time matters.
tar -C "$FP" -cf - . | zstd -q "-${ZSTD_LEVEL:-19}" --long=27 -T0 -o "$TAR_ZST" -f
echo
log "DONE"
echo "  tree:     $FP"
echo "  artifact: $TAR_ZST ($(du -h "$TAR_ZST" | cut -f1))"
echo "  sha256:   $(sha256 "$TAR_ZST")"
