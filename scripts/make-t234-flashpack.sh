#!/usr/bin/env bash
# Produce a Jetson Orin-family (T234) "flashpack" from an extracted WendyOS
# tegraflash bundle (jetson-agx-orin nvme/emmc, jetson-orin-nano nvme).
#
# The flashpack is the single, self-describing artifact the wendy CLI downloads,
# extracts and flashes from a Mac or Linux host. All of the offline (no-device)
# work that NVIDIA's initrd-flash would do — signing the boot chain and partition
# images and generating the RCM-boot blob — happens here on the x86_64 builder,
# so the host only has to: download, extract, run. (The NVIDIA flash tools are
# static i386 Linux binaries and do not run on macOS; nothing in the flashpack
# is an executable the host must run — stage2/tools/ scripts are optional
# Linux-host conveniences.)
#
# This mirrors initrd-flash's T234 branch (sign_binaries_t234 +
# copy_bootloader_files_t234 + the write_to_device_t234 XML rewrite) but stops
# before it touches USB. The device-connected phases are the host's job:
#   stage 1: send stage1/ files per rcmbootcmd.txt over USB recovery (the
#            tegrarcm_v2 RCM protocol) to boot the flashing initrd
#   stage 2: write stage2/flashpkg.ext4 to the "flashpkg" mass-storage LUN the
#            initrd exports (delivers command_sequence + boot firmware), then
#            write the partitions in stage2/flash/initrd-flash.xml to the
#            exported rootfs block device
#
# The board identity (BOARDID/FAB/BOARDSKU/BOARDREV/CHIPREV) comes from the
# DEFAULTS map in the bundle's .env.initrd-flash, so signing needs no EEPROM or
# ECID read. The resulting flashpack is therefore pinned to that module SKU.
#
# Trust boundary: the bundle is CI-internal input, produced minutes earlier by
# this same pipeline's Yocto build. Executing its tooling (env files, helper
# scripts, tegraflash, the NVIDIA binaries) is this script's purpose — anyone
# who can tamper with the bundle already controls the build outputs themselves.
#
# Usage:
#   make-t234-flashpack.sh --bundle-dir <extracted-tar> --out <dir> --version <ver>
#                          [--device <name>] [--storage <nvme|emmc>]
#
#   --bundle-dir  a directory holding an extracted *.tegraflash-tar (contains
#                 initrd-flash, tegra234-flash-helper.sh, .env.initrd-flash,
#                 flash.xml.in, the rootfs image, ...). MUTATED in place (gets
#                 signed/, rcmboot_blob/, bootloader_staging/, secureflash
#                 XMLs), so pass a scratch copy.
#   --out         where the flashpack/ tree and the .tar are written.
#   --version     WendyOS version string recorded in the manifest (e.g. 0.16.0
#                 or nightly-20260629T...). Names the output tar.
#   --device      published device name; derived from MACHINE when omitted
#                 (jetson-agx-orin-devkit-nvme-wendyos -> jetson-agx-orin).
#   --storage     rootfs storage; derived from MACHINE when omitted.
#
# Output:
#   <out>/flashpack/                                              the assembled tree
#   <out>/wendyos-<version>-<device>-<storage>.flashpack.tar.zst  the artifact CI uploads
set -euo pipefail

err() { echo "ERR: $*" >&2; exit 1; }
log() { echo "== $* =="; }

BUNDLE_DIR="" OUT="" VERSION="" DEVICE="" STORAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle-dir) BUNDLE_DIR="$2"; shift 2;;
        --out)        OUT="$2"; shift 2;;
        --version)    VERSION="$2"; shift 2;;
        --device)     DEVICE="$2"; shift 2;;
        --storage)    STORAGE="$2"; shift 2;;
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

# .env.initrd-flash assigns board identity into DEFAULTS[...]; declare the array
# so those assignments have a target.
declare -A DEFAULTS
set +u
# shellcheck disable=SC1091
. ./.env.initrd-flash
set -u
[ "${CHIPID:-}" = "0x23" ] || err "bundle is not T234 (CHIPID=${CHIPID:-unset}); use make-thor-flashpack.sh for T264"
[ -f "$FLASH_HELPER" ]     || err "$FLASH_HELPER missing from bundle"

if [ -z "$DEVICE" ] || [ -z "$STORAGE" ]; then
    if [[ "$MACHINE" =~ ^(jetson-[a-z0-9-]+)-devkit-(nvme|emmc)-wendyos$ ]]; then
        DEVICE="${DEVICE:-${BASH_REMATCH[1]}}"
        STORAGE="${STORAGE:-${BASH_REMATCH[2]}}"
    else
        err "cannot derive --device/--storage from MACHINE=$MACHINE; pass them explicitly"
    fi
fi

# Board identity pinned at build time; with BOARDID/FAB set the helper skips
# its EEPROM/ECID device queries and signing runs fully offline. Empty
# keyfiles select the zero-key path unfused BootROMs accept.
export MACHINE
export BOARDID="${DEFAULTS[BOARDID]-}" FAB="${DEFAULTS[FAB]-}" BOARDSKU="${DEFAULTS[BOARDSKU]-}"
export BOARDREV="${DEFAULTS[BOARDREV]-}" CHIPREV="${DEFAULTS[CHIPREV]-}"
export serial_number=""
[ -n "$BOARDID" ] && [ -n "$FAB" ] || err "DEFAULTS[BOARDID]/[FAB] missing from .env.initrd-flash"

logfile="$here/make-t234-flashpack.log"
: > "$logfile"

# Reuse initrd-flash's own function verbatim (definition only — sourcing the
# whole script would run its device-waiting main flow). If a future BSP renames
# it, this extraction is where it breaks, loudly.
body="$(awk '/^copy_bootloader_files_t234\(\)/{g=1} g{print} g&&/^}/{exit}' initrd-flash)"
[ -n "$body" ] || err "could not extract copy_bootloader_files_t234() from initrd-flash"
eval "$body"

# ---------------------------------------------------------------------------
log "Step 1: sign boot chain + partition images, generate RCM-boot blob (no device)"
# ---------------------------------------------------------------------------
rm -rf signed rcmboot_blob bootloader_staging secureflash.xml boardvars.sh
log "zero-key signing (unfused hardware only; fused boards need real keys)"
# shellcheck disable=SC2153  # DTBFILE/EMC_BCT/... come from the sourced .env.initrd-flash
"./$FLASH_HELPER" --no-flash --sign -u "" -v "" \
    flash.xml.in "$DTBFILE" "$EMC_BCT" "$ODMDATA" "$LNXFILE" "$ROOTFS_IMAGE" \
    2>&1 | tee -a "$logfile" || err "internal signing failed"
cp secureflash.xml internal-secureflash.xml
[ -f rcmboot_blob/rcmbootcmd.txt ] || err "signing did not produce rcmboot_blob/rcmbootcmd.txt"
# The helper resolves CHIP_SKU (from flashvars) and writes the full identity here.
set +u
# shellcheck disable=SC1091
. ./boardvars.sh
set -u

# ---------------------------------------------------------------------------
log "Step 2: stage boot-device firmware (QSPI/eMMC-boot)"
# ---------------------------------------------------------------------------
# Must run before any external sign: each helper run regenerates flash.idx for
# its own layout, and the staging needs the internal one with the 3:0/0:3 boot
# entries (same ordering as sign_binaries_t234).
rm -rf bootloader_staging && mkdir bootloader_staging
# initrd-flash runs without nounset and its function relies on unset-variable
# expansion; relax -u only around the borrowed code.
set +u
copy_bootloader_files_t234 bootloader_staging || err "bootloader staging failed"
set -u
BOOT_DEVICE_TYPE="$(cat bootloader_staging/boot_device_type)"

# ---------------------------------------------------------------------------
log "Step 3: external layout (sign or copy)"
# ---------------------------------------------------------------------------
if [ -e external-flash.xml.in ]; then
    if grep -q 'oem_sign="true"' external-flash.xml.in 2>/dev/null; then
        "./$FLASH_HELPER" --no-flash --sign --external-device -u "" -v "" \
            external-flash.xml.in "$DTBFILE" "$EMC_BCT" "$ODMDATA" "$LNXFILE" "$ROOTFS_IMAGE" \
            2>&1 | tee -a "$logfile" || err "external signing failed"
        mv secureflash.xml external-secureflash.xml
    else
        cp external-flash.xml.in external-secureflash.xml
    fi
fi

# ---------------------------------------------------------------------------
log "Step 4: build the final flash layout XML (what write_to_device_t234 builds)"
# ---------------------------------------------------------------------------
: "${EXTERNAL_ROOTFS_DRIVE:=0}"
: "${NO_INTERNAL_STORAGE:=0}"
if [ "$EXTERNAL_ROOTFS_DRIVE" = 1 ]; then
    layout=external-flash.xml.in
else
    layout=flash.xml.in
fi
rewritefiles="internal-secureflash.xml"
[ ! -e external-secureflash.xml ] || rewritefiles="external-secureflash.xml,$rewritefiles"
./nvflashxmlparse --rewrite-contents-from=$rewritefiles -o initrd-flash.xml "$layout"
if [ -n "${DATAFILE:-}" ]; then
    datased="-es,DATAFILE,$DATAFILE,"
else
    datased="-e/DATAFILE/d"
fi
# Pre-signed layouts name the sparse image; convert back to the raw image name.
simgname="${ROOTFS_IMAGE%.*}.img"
# shellcheck disable=SC2086  # $datased is intentionally a sed arg, split on space
sed -i.bak -e"s,$simgname,$ROOTFS_IMAGE," -e"s,APPFILE_b,$ROOTFS_IMAGE," -e"s,APPFILE,$ROOTFS_IMAGE," \
    -e"s,DTB_FILE,kernel_$DTBFILE," $datased initrd-flash.xml
rm -f initrd-flash.xml.bak

# ---------------------------------------------------------------------------
log "Step 5: assemble flashpack tree"
# ---------------------------------------------------------------------------
FP="$OUT/flashpack"
rm -rf "$FP"
mkdir -p "$FP/stage1" "$FP/stage2/flash" "$FP/stage2/tools"

# stage1 — the RCM-boot blob the host sends per rcmbootcmd.txt (everything in
# rcmboot_blob except the tegrarcm_v2 symlink, which is a Linux-x86 binary the
# host replaces with its own RCM implementation).
S1_FIXED=(br_bct_BR.bct
          mb1_t234_prod_aligned_sigheader.bin.encrypt
          psc_bl1_t234_prod_aligned_sigheader.bin.encrypt
          mb1_bct_MB1_sigheader.bct.encrypt
          mem_rcm_sigheader.bct.encrypt
          blob.bin
          rcmbootcmd.txt)
for f in "${S1_FIXED[@]}"; do
    [ -f "rcmboot_blob/$f" ] || err "stage1 artifact missing: rcmboot_blob/$f"
    cp "rcmboot_blob/$f" "$FP/stage1/"
done

# stage2/flash — the final layout XML plus every partition image it references
# (from the rootfs-device sections; boot-device firmware travels in flashpkg).
# Signed images live in signed/, unsigned ones (rootfs, esp, config) in the
# bundle root — same lookup order as initrd-flash's copy_signed_binaries,
# but extracting the one field we need instead of eval'ing the line.
# Hardlink when possible: the rootfs image is multi-GB and nothing writes to
# the sources between here and the pack step.
stage_image() { ln -f "$1" "$2" 2>/dev/null || cp "$1" "$2"; }
cp initrd-flash.xml "$FP/stage2/flash/"
missing=0
while read -r line; do
    partfile="$(printf '%s' "$line" | sed -n 's/.*;partfile="\([^"]*\)".*/\1/p')"
    [ -n "$partfile" ] || continue
    [ -e "$FP/stage2/flash/$partfile" ] && continue
    if [ -e "signed/$partfile" ]; then
        stage_image "signed/$partfile" "$FP/stage2/flash/$partfile"
    elif [ -e "$partfile" ]; then
        stage_image "$partfile" "$FP/stage2/flash/$partfile"
    else
        echo "  MISSING: $partfile" >&2; missing=$((missing+1))
    fi
done < <(./nvflashxmlparse -t rootfs initrd-flash.xml)
[ "$missing" = 0 ] || err "$missing partition file(s) referenced by initrd-flash.xml are missing"

# stage2/secureflash XMLs — reference copies for hosts that rebuild the layout
# themselves instead of using initrd-flash.xml.
cp internal-secureflash.xml "$FP/stage2/"
[ ! -e external-secureflash.xml ] || cp external-secureflash.xml "$FP/stage2/"

# stage2/flashpkg — the tree the flashing initrd expects on its "flashpkg" LUN:
# conf/command_sequence drives the device-side steps, bootloader/ is the boot
# firmware it programs, logs/ + status are written by the device. Mirrors
# generate_flash_package_t234 with default options (no erase-nvme).
PKG="$FP/stage2/flashpkg"
mkdir -p "$PKG/conf" "$PKG/bootloader" "$PKG/logs"
cp bootloader_staging/* "$PKG/bootloader/"
{
    echo "bootloader"
    echo "extra-pre-wipe"
    [ "$EXTERNAL_ROOTFS_DRIVE" = 0 ] || [ "$NO_INTERNAL_STORAGE" = 1 ] || echo "erase-mmc"
    echo "export-devices $ROOTFS_DEVICE"
    echo "extra"
    echo "reboot"
} > "$PKG/conf/command_sequence"
echo "PENDING: expecting command sequence from host" > "$PKG/status"

# stage2/flashpkg.ext4 — the same tree as a ready-made 128 MiB ext4 image,
# byte-writable straight onto the flashpkg LUN (which the initrd creates at
# exactly 128 MiB). Lets macOS hosts skip ext4 filesystem authoring entirely.
if command -v mke2fs >/dev/null 2>&1; then
    pkgtmp="$(mktemp -d)"
    mkdir "$pkgtmp/flashpkg"
    cp -R "$PKG/." "$pkgtmp/flashpkg/"
    truncate -s 128M "$FP/stage2/flashpkg.ext4" 2>/dev/null || \
        dd if=/dev/zero of="$FP/stage2/flashpkg.ext4" bs=1M count=128 status=none
    mke2fs -q -F -t ext4 -d "$pkgtmp" "$FP/stage2/flashpkg.ext4" || err "mke2fs failed for flashpkg.ext4"
    rm -rf "$pkgtmp"
else
    err "mke2fs not found (install e2fsprogs); required to prebuild flashpkg.ext4"
fi

# stage2/tools — host-side helper scripts (bash/python, no NVIDIA binaries);
# usable directly on a Linux host, reference material elsewhere.
cp make-sdcard nvflashxmlparse "$FP/stage2/tools/"

# ---------------------------------------------------------------------------
log "Step 6: validate"
# ---------------------------------------------------------------------------
magic() { head -c4 "$1" | LC_ALL=C tr -d '\0'; }
[ "$(magic "$FP/stage1/br_bct_BR.bct")" = "BCTB" ] || err "br_bct_BR.bct: bad magic (expected BCTB)"
for f in mb1_t234_prod_aligned_sigheader.bin.encrypt \
         psc_bl1_t234_prod_aligned_sigheader.bin.encrypt \
         mb1_bct_MB1_sigheader.bct.encrypt \
         mem_rcm_sigheader.bct.encrypt; do
    [ "$(magic "$FP/stage1/$f")" = "NVDA" ] || err "$f: bad magic (expected NVDA)"
done
[ -s "$FP/stage1/blob.bin" ] || err "blob.bin is empty"
grep -q "download bct_br" "$FP/stage1/rcmbootcmd.txt" || err "rcmbootcmd.txt has no bct_br download"
[ "$(stat -c%s "$FP/stage2/flashpkg.ext4" 2>/dev/null || stat -f%z "$FP/stage2/flashpkg.ext4")" = 134217728 ] \
    || err "flashpkg.ext4 is not exactly 128 MiB"
[ -s "$PKG/bootloader/partitions.conf" ]   || err "flashpkg bootloader/partitions.conf missing"
[ -s "$PKG/bootloader/boot_device_type" ]  || err "flashpkg bootloader/boot_device_type missing"
echo "  boot device: $BOOT_DEVICE_TYPE, rootfs device: $ROOTFS_DEVICE"
echo "  flash images: $(find "$FP/stage2/flash" -type f | wc -l | tr -d ' ') files"

# ---------------------------------------------------------------------------
log "Step 7: write manifest.json"
# ---------------------------------------------------------------------------
# The manifest schema is defined authoritatively by the Go consumer
# (go/internal/cli/tegraflash/flashpack/flashpack.go: type Manifest). Keep these
# fields in sync with it. The rcm send phases are parsed from rcmbootcmd.txt so
# the manifest can never drift from what tegraflash generated. Only stage-1
# files and flashpkg.ext4 get integrity hashes: stage-2 flash images are
# covered by the tarball checksum verified on download.
VERSION="$VERSION" DEVICE="$DEVICE" STORAGE="$STORAGE" MACHINE="$MACHINE" \
    BOARDID="$BOARDID" FAB="$FAB" BOARDSKU="$BOARDSKU" BOARDREV="$BOARDREV" \
    CHIP_SKU="${CHIP_SKU:-}" ROOTFS_DEVICE="$ROOTFS_DEVICE" \
    BOOT_DEVICE_TYPE="$BOOT_DEVICE_TYPE" ROOTFS_IMAGE="$ROOTFS_IMAGE" \
    EXTERNAL_ROOTFS_DRIVE="$EXTERNAL_ROOTFS_DRIVE" FP="$FP" \
    python3 - <<'PY'
import os, json, hashlib, pathlib, re, sys
fp = pathlib.Path(os.environ["FP"])
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()
files = {}
for p in sorted((fp / "stage1").rglob("*")) + [fp / "stage2" / "flashpkg.ext4"]:
    if p.is_file():
        rel = str(p.relative_to(fp))
        files[rel] = {"sha256": sha(p), "size": p.stat().st_size}
# rcmbootcmd.txt is authoritative for the send order: one tegrarcm_v2
# invocation per line, each a sequence of "--download <type> <file>".
phases = []
for line in (fp / "stage1" / "rcmbootcmd.txt").read_text().splitlines():
    dls = re.findall(r"--download\s+(\S+)\s+(\S+)", line)
    if dls:
        phases.append([{"type": t, "file": f"stage1/{f}"} for t, f in dls])
if len(phases) != 2:
    sys.exit(f"ERR: expected 2 rcm phases in rcmbootcmd.txt, got {len(phases)} — "
             "the BSP changed the RCM boot contract; the wendy CLI needs updating too")
m = {
    "schema": 1,
    "family": "t234",
    "wendyos_version": os.environ["VERSION"],
    "rcm_phases": phases,
    "layout": {
        "stage1": "stage1",
        "flashpkg_image": "stage2/flashpkg.ext4",
        "flashpkg_dir": "stage2/flashpkg",
        "flash_dir": "stage2/flash",
        "flash_layout": "stage2/flash/initrd-flash.xml",
        "tools": "stage2/tools",
    },
    "rootfs_device": os.environ["ROOTFS_DEVICE"],
    "rootfs_image": os.environ["ROOTFS_IMAGE"],
    "boot_device_type": os.environ["BOOT_DEVICE_TYPE"],
    "external_rootfs": os.environ["EXTERNAL_ROOTFS_DRIVE"] == "1",
    "files": files,
    # provenance only (not read by wendy)
    "board": os.environ["DEVICE"],
    "storage": os.environ["STORAGE"],
    "machine": os.environ["MACHINE"],
    "chip": "0x23",
    "board_id": os.environ["BOARDID"],
    "board_fab": os.environ["FAB"],
    "board_sku": os.environ["BOARDSKU"],
    "board_rev": os.environ["BOARDREV"],
    "chip_sku": os.environ.get("CHIP_SKU") or None,
}
(fp / "manifest.json").write_text(json.dumps(m, indent=2) + "\n")
print(f"  manifest: {len(files)} files hashed, {sum(len(p) for p in phases)} rcm downloads")
PY

# ---------------------------------------------------------------------------
log "Step 8: pack (.tar.zst — what the wendy CLI downloads and extracts)"
# ---------------------------------------------------------------------------
TAR_ZST="$OUT/wendyos-${VERSION}-${DEVICE}-${STORAGE}.flashpack.tar.zst"
# Stream tar straight into zstd so we never write the ~6.5 GB uncompressed tar.
tar -C "$FP" -cf - . | zstd -q "-${ZSTD_LEVEL:-19}" --long=27 -T0 -o "$TAR_ZST" -f
echo
log "DONE"
echo "  tree:     $FP"
echo "  artifact: $TAR_ZST ($(du -h "$TAR_ZST" | cut -f1))"
