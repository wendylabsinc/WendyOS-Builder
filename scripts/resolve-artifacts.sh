#!/usr/bin/env bash
# resolve-artifacts.sh — turn (DEVICE, STORAGE, MACHINE, DEPLOY_DIR) into the
# concrete Yocto build-artifact paths that build.yml uploads.
#
# .github/device-artifacts.json is the SINGLE SOURCE OF TRUTH for how each
# device+storage combo's flashable artifacts are named and which extras
# (recovery tegraflash bundle, bmap, Thor flashpack, publisher --storage) apply.
# This script is its only consumer: it turns that map plus a live deploy dir
# into paths, and fails loudly — naming the device, the map entry, the expected
# pattern and the actual deploy-dir contents — when an expected artifact is
# absent. It replaces the fragile per-device glob + if/elif chains build.yml
# used to carry inline, which drifted ~11 times (JetPack artifact renames,
# sdimg-vs-wic, .tegraflash-tar vs .tegraflash-tar.zst, cross-board image
# bleed). With the naming rules in one checked-in map, the next rename is a
# one-line data edit here instead of a shell surgery in the workflow.
#
# Inputs (env vars, matching build.yml's existing style):
#   DEVICE      e.g. jetson-agx-orin
#   STORAGE     e.g. nvme | emmc | sd
#   MACHINE     Yocto MACHINE, e.g. jetson-agx-orin-devkit-nvme-wendyos
#   DEPLOY_DIR  build/tmp/deploy/images/<MACHINE>
#   MAP_FILE    (optional) override the map path — used by the tests
#
# Output: KEY=VALUE lines on stdout, safe to `eval` in a step or append to
# $GITHUB_ENV. Diagnostics and errors go to stderr.
#   IMAGE_KIND         generated-nvme-img | tegraflash-bundle |
#                      sdimg-gz-with-wic-fallback | wic-disk
#   IMAGE_FILE         primary artifact path. For generated-nvme-img this is the
#                      MACHINE-scoped target path the "Generate flashable image"
#                      step writes (it does NOT exist at Yocto deploy time, so it
#                      is intentionally not existence-checked here). For sdimg it
#                      is the readlink-resolved raw image the workflow gzips.
#   TEGRAFLASH_BUNDLE  resolved tegraflash bundle (recovery/flash artifact), or
#                      empty when the device has none (Raspberry Pi).
#   RECOVERY_EXPECTED  true when a tegraflash bundle is expected (all Jetsons).
#   BMAP_REQUIRED      true when the workflow should `bmaptool create` the image.
#   FLASHPACK_REQUIRED true when a Thor flashpack is built and attached.
#   PASS_STORAGE       true when the publisher gets --storage (multi-storage device).
#   RPI_NEEDS_GZIP     true when IMAGE_FILE is a raw sdimg the workflow must gzip.
#
# On a missing expected artifact the script exits non-zero. The df/ls dump in
# deploy_dir_diagnostics() is kept for now to catch the /wendy scratch
# exhaustion "artifact vanished between build and upload" symptom; a later
# gated spec removes it.
set -euo pipefail

: "${DEVICE:?DEVICE is required}"
: "${STORAGE:?STORAGE is required}"
: "${MACHINE:?MACHINE is required}"
: "${DEPLOY_DIR:?DEPLOY_DIR is required}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAP_FILE="${MAP_FILE:-$SCRIPT_DIR/../.github/device-artifacts.json}"

if [[ ! -f "$MAP_FILE" ]]; then
  echo "::error::device artifact map not found at $MAP_FILE" >&2
  exit 1
fi

# Kept for now (see header): df + ls dump to catch the /wendy scratch
# exhaustion symptom where an artifact present during the build has vanished by
# upload time. A later gated spec deletes this function and its call sites.
deploy_dir_diagnostics() {
  {
    echo "-- df -h $DEPLOY_DIR --"
    df -h "$DEPLOY_DIR" 2>/dev/null || true
    echo "-- ls -la $DEPLOY_DIR --"
    ls -la "$DEPLOY_DIR" 2>/dev/null || true
  } >&2
}

# fail <message>: emit an informative ::error:: plus the deploy-dir state, exit 1.
fail() {
  echo "::error::$1" >&2
  deploy_dir_diagnostics
  exit 1
}

KEY="$DEVICE/$STORAGE"
entry=$(jq -c --arg k "$KEY" '.[$k] // empty' "$MAP_FILE")
if [[ -z "$entry" ]]; then
  valid=$(jq -r 'keys | join(", ")' "$MAP_FILE")
  echo "::error::no device-artifacts map entry for '$KEY' in $MAP_FILE (valid keys: $valid)" >&2
  exit 1
fi

IMAGE_KIND=$(jq -r '.image_kind' <<<"$entry")
RECOVERY_EXPECTED=$(jq -r '.recovery_bundle_expected' <<<"$entry")
BMAP_REQUIRED=$(jq -r '.bmap' <<<"$entry")
FLASHPACK_REQUIRED=$(jq -r '.flashpack' <<<"$entry")
PASS_STORAGE=$(jq -r '.pass_storage' <<<"$entry")

# Resolve the tegraflash bundle by glob, matching the historical logic: JP7 /
# r38.4.x (Thor, tegra264) may deploy a compressed .tegraflash-tar.zst and the
# unsuffixed "latest" symlink is not guaranteed, so accept both suffixes.
TEGRAFLASH_BUNDLE=""
if [[ "$RECOVERY_EXPECTED" == "true" || "$IMAGE_KIND" == "tegraflash-bundle" ]]; then
  TEGRAFLASH_BUNDLE=$(find "$DEPLOY_DIR" -maxdepth 1 \
    \( -name "wendyos-image-${MACHINE}.tegraflash-tar" \
       -o -name "wendyos-image-${MACHINE}.tegraflash-tar.zst" \) \
    -print -quit 2>/dev/null || true)
fi

RPI_NEEDS_GZIP=false
case "$IMAGE_KIND" in
  tegraflash-bundle)
    # eMMC and Thor NVMe ship no offline disk image; the tegraflash bundle IS
    # the flash artifact. A missing bundle here is fatal.
    if [[ -z "$TEGRAFLASH_BUNDLE" || ! -f "$TEGRAFLASH_BUNDLE" ]]; then
      fail "no tegraflash bundle for $KEY ($MACHINE): expected wendyos-image-${MACHINE}.tegraflash-tar or .tegraflash-tar.zst in $DEPLOY_DIR (map entry image_kind=tegraflash-bundle)"
    fi
    IMAGE_FILE="$TEGRAFLASH_BUNDLE"
    ;;
  generated-nvme-img)
    # The offline NVMe image is produced by build.yml's "Generate flashable
    # image" step from the extracted bundle; it does not exist at Yocto deploy
    # time, so its existence is NOT validated here (the workflow keeps the
    # stale-image guard for it). Resolve only its canonical MACHINE-scoped path,
    # which the generate step writes to and the upload step reads.
    IMAGE_FILE="$DEPLOY_DIR/wendyos-image-${MACHINE}-nvme.img"
    ;;
  sdimg-gz-with-wic-fallback)
    sdimg="$DEPLOY_DIR/wendyos-image-${MACHINE}.sdimg"
    wic="$DEPLOY_DIR/wendyos-image-${MACHINE}.rootfs.wic"
    if [[ -f "$sdimg" ]]; then
      # Mender build: prefer .sdimg. Resolve the Yocto symlink chain now — gzip
      # fails with ELOOP on deep chains, so the workflow must gzip the real
      # file, not the symlink.
      IMAGE_FILE=$(readlink -f "$sdimg")
      RPI_NEEDS_GZIP=true
    elif [[ -f "$wic" ]]; then
      # Pre-Mender fallback.
      IMAGE_FILE="$wic"
    else
      fail "no Raspberry Pi image for $KEY ($MACHINE): expected wendyos-image-${MACHINE}.sdimg (preferred) or wendyos-image-${MACHINE}.rootfs.wic in $DEPLOY_DIR (map entry image_kind=sdimg-gz-with-wic-fallback)"
    fi
    ;;
  wic-disk)
    # Generic x86_64 PC: a single directly-flashable UEFI/BIOS .wic disk image
    # (IMAGE_FSTYPES="wic wic.bmap ..." in genericx86-64-wendyos.conf). No A/B
    # OTA (WENDYOS_OTA="none"), so no tegraflash bundle and no .wendy/.mender.
    # Uploaded as-is (bmap generated in the workflow like the RPi wic path); the
    # publisher recompresses .wic. A missing wic here is fatal.
    wic="$DEPLOY_DIR/wendyos-image-${MACHINE}.rootfs.wic"
    if [[ ! -f "$wic" ]]; then
      fail "no x86 disk image for $KEY ($MACHINE): expected wendyos-image-${MACHINE}.rootfs.wic in $DEPLOY_DIR (map entry image_kind=wic-disk)"
    fi
    IMAGE_FILE="$wic"
    ;;
  *)
    echo "::error::unknown image_kind '$IMAGE_KIND' for $KEY in $MAP_FILE" >&2
    exit 1
    ;;
esac

# %q-quote every value: the workflow consumes this via eval, so paths must
# survive word-splitting/globbing even if a future deploy path grows a space.
printf '%s=%q\n' \
  IMAGE_KIND "$IMAGE_KIND" \
  IMAGE_FILE "$IMAGE_FILE" \
  TEGRAFLASH_BUNDLE "$TEGRAFLASH_BUNDLE" \
  RECOVERY_EXPECTED "$RECOVERY_EXPECTED" \
  BMAP_REQUIRED "$BMAP_REQUIRED" \
  FLASHPACK_REQUIRED "$FLASHPACK_REQUIRED" \
  PASS_STORAGE "$PASS_STORAGE" \
  RPI_NEEDS_GZIP "$RPI_NEEDS_GZIP"

echo "resolve-artifacts: $KEY -> kind=$IMAGE_KIND image=$IMAGE_FILE bundle=${TEGRAFLASH_BUNDLE:-<none>}" >&2
