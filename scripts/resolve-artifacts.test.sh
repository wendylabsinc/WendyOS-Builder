#!/usr/bin/env bash
# Tests for resolve-artifacts.sh — plain bash, no framework.
#
# Builds fixture deploy-dir trees under mktemp and asserts that:
#   (a) each device family resolves the correct artifact set,
#   (b) a missing expected artifact exits non-zero with an informative error,
#   (c) every device+storage combo in build.yml's matrix has a map entry.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVER="$SCRIPT_DIR/resolve-artifacts.sh"
MAP="$SCRIPT_DIR/../.github/device-artifacts.json"

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL - $1"; }

# run_resolver DEVICE STORAGE MACHINE DEPLOY_DIR -> stdout=KEY=VALUE, returns rc.
run_resolver() {
  DEVICE="$1" STORAGE="$2" MACHINE="$3" DEPLOY_DIR="$4" MAP_FILE="$MAP" \
    bash "$RESOLVER"
}

# field NAME <<<"$out" — extract a KEY=VALUE field from resolver output.
# Values are %q-quoted (the workflow consumes them via eval), so parse the
# same way the workflow does: eval the line and print the variable.
field() {
  local line
  line=$(grep -E "^$1=" | head -1)
  [[ -n "$line" ]] || return 0
  (
    eval "$line"
    eval "printf '%s' \"\${$1}\""
  )
}

# assert_eq label expected actual
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

newdir() { mktemp -d "${TMPDIR:-/tmp}/resolve-test.XXXXXX"; }

# ---------------------------------------------------------------------------
# (a) Per-family resolution
# ---------------------------------------------------------------------------

# Jetson NVMe (generated-nvme-img): bundle present, nvme .img absent — the
# resolver must NOT fail (the image is generated later) and must resolve the
# MACHINE-scoped target path plus the recovery bundle.
test_jetson_nvme() {
  local d M; d=$(newdir); M=jetson-agx-orin-devkit-nvme-wendyos
  : >"$d/wendyos-image-$M.tegraflash-tar"
  local out; out=$(run_resolver jetson-agx-orin nvme "$M" "$d"); local rc=$?
  assert_eq "jetson nvme: exits 0" 0 "$rc"
  assert_eq "jetson nvme: kind"        generated-nvme-img "$(field IMAGE_KIND        <<<"$out")"
  assert_eq "jetson nvme: image"       "$d/wendyos-image-$M-nvme.img" "$(field IMAGE_FILE <<<"$out")"
  assert_eq "jetson nvme: bundle"      "$d/wendyos-image-$M.tegraflash-tar" "$(field TEGRAFLASH_BUNDLE <<<"$out")"
  assert_eq "jetson nvme: recovery"    true  "$(field RECOVERY_EXPECTED  <<<"$out")"
  assert_eq "jetson nvme: bmap"        true  "$(field BMAP_REQUIRED      <<<"$out")"
  assert_eq "jetson nvme: flashpack"   false "$(field FLASHPACK_REQUIRED <<<"$out")"
  assert_eq "jetson nvme: pass_storage" true "$(field PASS_STORAGE       <<<"$out")"
  rm -rf "$d"
}

# Jetson eMMC (tegraflash-bundle): the bundle is the image; no bmap.
test_jetson_emmc() {
  local d M; d=$(newdir); M=jetson-agx-orin-devkit-emmc-wendyos
  : >"$d/wendyos-image-$M.tegraflash-tar"
  local out; out=$(run_resolver jetson-agx-orin emmc "$M" "$d"); local rc=$?
  assert_eq "jetson emmc: exits 0" 0 "$rc"
  assert_eq "jetson emmc: kind"   tegraflash-bundle "$(field IMAGE_KIND <<<"$out")"
  assert_eq "jetson emmc: image"  "$d/wendyos-image-$M.tegraflash-tar" "$(field IMAGE_FILE <<<"$out")"
  assert_eq "jetson emmc: bundle" "$d/wendyos-image-$M.tegraflash-tar" "$(field TEGRAFLASH_BUNDLE <<<"$out")"
  assert_eq "jetson emmc: bmap"        false "$(field BMAP_REQUIRED <<<"$out")"
  assert_eq "jetson emmc: pass_storage" true "$(field PASS_STORAGE  <<<"$out")"
  rm -rf "$d"
}

# Thor (tegraflash-bundle + flashpack, no --storage).
test_thor() {
  local d M; d=$(newdir); M=jetson-agx-thor-devkit-nvme-wendyos
  : >"$d/wendyos-image-$M.tegraflash-tar"
  local out; out=$(run_resolver jetson-agx-thor nvme "$M" "$d"); local rc=$?
  assert_eq "thor: exits 0" 0 "$rc"
  assert_eq "thor: kind"        tegraflash-bundle "$(field IMAGE_KIND <<<"$out")"
  assert_eq "thor: image"       "$d/wendyos-image-$M.tegraflash-tar" "$(field IMAGE_FILE <<<"$out")"
  assert_eq "thor: flashpack"   true  "$(field FLASHPACK_REQUIRED <<<"$out")"
  assert_eq "thor: bmap"        false "$(field BMAP_REQUIRED <<<"$out")"
  assert_eq "thor: pass_storage" false "$(field PASS_STORAGE <<<"$out")"
  rm -rf "$d"
}

# tegraflash .zst variant resolves too (JP7 / r38.4.x compressed bundle).
test_tegraflash_zst() {
  local d M; d=$(newdir); M=jetson-orin-nano-devkit-nvme-wendyos
  : >"$d/wendyos-image-$M.tegraflash-tar.zst"
  local out; out=$(run_resolver jetson-orin-nano nvme "$M" "$d"); local rc=$?
  assert_eq "zst variant: exits 0" 0 "$rc"
  assert_eq "zst variant: kind"   generated-nvme-img "$(field IMAGE_KIND <<<"$out")"
  assert_eq "zst variant: bundle" "$d/wendyos-image-$M.tegraflash-tar.zst" "$(field TEGRAFLASH_BUNDLE <<<"$out")"
  rm -rf "$d"
}

# RPi sdimg: prefer .sdimg, resolve the symlink chain to the real file, gzip flag set.
test_rpi_sdimg() {
  local d M; d=$(newdir); M=raspberrypi4-64-wendyos
  : >"$d/wendyos-image-$M.rootfs.wic.real"          # decoy: wic exists too
  : >"$d/wendyos-image-$M.rootfs.wic"
  : >"$d/wendyos-image-$M.sdimg.real"               # the real deep-chain target
  ln -s "wendyos-image-$M.sdimg.real" "$d/wendyos-image-$M.sdimg"
  local out; out=$(run_resolver raspberry-pi-4 sd "$M" "$d"); local rc=$?
  assert_eq "rpi sdimg: exits 0" 0 "$rc"
  assert_eq "rpi sdimg: kind"       sdimg-gz-with-wic-fallback "$(field IMAGE_KIND <<<"$out")"
  assert_eq "rpi sdimg: needs_gzip" true "$(field RPI_NEEDS_GZIP <<<"$out")"
  # readlink -f resolves the symlink to the real file.
  assert_eq "rpi sdimg: image real path" "$d/wendyos-image-$M.sdimg.real" "$(field IMAGE_FILE <<<"$out")"
  assert_eq "rpi sdimg: no bundle" "" "$(field TEGRAFLASH_BUNDLE <<<"$out")"
  assert_eq "rpi sdimg: bmap"        true  "$(field BMAP_REQUIRED <<<"$out")"
  assert_eq "rpi sdimg: pass_storage" false "$(field PASS_STORAGE <<<"$out")"
  rm -rf "$d"
}

# RPi wic fallback: no .sdimg present.
test_rpi_wic() {
  local d M; d=$(newdir); M=raspberrypi3-64-wendyos
  : >"$d/wendyos-image-$M.rootfs.wic"
  local out; out=$(run_resolver raspberry-pi-3 sd "$M" "$d"); local rc=$?
  assert_eq "rpi wic: exits 0" 0 "$rc"
  assert_eq "rpi wic: kind"       sdimg-gz-with-wic-fallback "$(field IMAGE_KIND <<<"$out")"
  assert_eq "rpi wic: needs_gzip" false "$(field RPI_NEEDS_GZIP <<<"$out")"
  assert_eq "rpi wic: image"      "$d/wendyos-image-$M.rootfs.wic" "$(field IMAGE_FILE <<<"$out")"
  rm -rf "$d"
}

# rpi-5 passes --storage (both nvme and sd).
test_rpi5_pass_storage() {
  local d M; d=$(newdir); M=raspberrypi5-nvme-wendyos
  : >"$d/wendyos-image-$M.rootfs.wic"
  local out; out=$(run_resolver raspberry-pi-5 nvme "$M" "$d")
  assert_eq "rpi5: pass_storage" true "$(field PASS_STORAGE <<<"$out")"
  rm -rf "$d"
}

# Generic x86_64 (wic-disk): single .wic disk image, no bundle, no gzip; bmap
# is generated by the workflow (bmap=true in the map).
test_x86_wic_disk() {
  local d M; d=$(newdir); M=genericx86-64-wendyos
  : >"$d/wendyos-image-$M.rootfs.wic"
  local out; out=$(run_resolver generic-x86-64 disk "$M" "$d"); local rc=$?
  assert_eq "x86 wic-disk: exits 0" 0 "$rc"
  assert_eq "x86 wic-disk: kind"        wic-disk "$(field IMAGE_KIND <<<"$out")"
  assert_eq "x86 wic-disk: image"       "$d/wendyos-image-$M.rootfs.wic" "$(field IMAGE_FILE <<<"$out")"
  assert_eq "x86 wic-disk: no bundle"   "" "$(field TEGRAFLASH_BUNDLE <<<"$out")"
  assert_eq "x86 wic-disk: recovery"    false "$(field RECOVERY_EXPECTED <<<"$out")"
  assert_eq "x86 wic-disk: bmap"        true  "$(field BMAP_REQUIRED <<<"$out")"
  assert_eq "x86 wic-disk: flashpack"   false "$(field FLASHPACK_REQUIRED <<<"$out")"
  assert_eq "x86 wic-disk: pass_storage" false "$(field PASS_STORAGE <<<"$out")"
  assert_eq "x86 wic-disk: no gzip"     false "$(field RPI_NEEDS_GZIP <<<"$out")"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# (b) Missing expected artifact exits non-zero with an informative error
# ---------------------------------------------------------------------------

# tegraflash-bundle kind with an empty deploy dir -> fatal, error names the
# device, the pattern and lists the deploy dir.
test_missing_bundle_fatal() {
  local d M; d=$(newdir); M=jetson-agx-orin-devkit-emmc-wendyos
  local out; out=$(run_resolver jetson-agx-orin emmc "$M" "$d" 2>&1); local rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "missing bundle: non-zero exit"; else bad "missing bundle: expected non-zero"; fi
  if grep -q "jetson-agx-orin/emmc" <<<"$out"; then ok "missing bundle: names device/storage"; else bad "missing bundle: error lacks device/storage"; fi
  if grep -q "tegraflash-tar" <<<"$out"; then ok "missing bundle: names expected pattern"; else bad "missing bundle: error lacks pattern"; fi
  if grep -q "ls -la" <<<"$out"; then ok "missing bundle: dumps deploy dir"; else bad "missing bundle: no deploy-dir dump"; fi
  rm -rf "$d"
}

# RPi with neither sdimg nor wic -> fatal.
test_missing_rpi_fatal() {
  local d M; d=$(newdir); M=raspberrypi3-64-wendyos
  local out; out=$(run_resolver raspberry-pi-3 sd "$M" "$d" 2>&1); local rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "missing rpi image: non-zero exit"; else bad "missing rpi image: expected non-zero"; fi
  if grep -q "sdimg" <<<"$out"; then ok "missing rpi image: names sdimg pattern"; else bad "missing rpi image: error lacks pattern"; fi
  rm -rf "$d"
}

# x86 wic-disk with an empty deploy dir -> fatal, names the combo and pattern.
test_missing_x86_fatal() {
  local d M; d=$(newdir); M=genericx86-64-wendyos
  local out; out=$(run_resolver generic-x86-64 disk "$M" "$d" 2>&1); local rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "missing x86 image: non-zero exit"; else bad "missing x86 image: expected non-zero"; fi
  if grep -q "generic-x86-64/disk" <<<"$out"; then ok "missing x86 image: names device/storage"; else bad "missing x86 image: error lacks device/storage"; fi
  if grep -q "rootfs.wic" <<<"$out"; then ok "missing x86 image: names wic pattern"; else bad "missing x86 image: error lacks pattern"; fi
  rm -rf "$d"
}

# Unknown device/storage combo -> fatal, lists valid keys.
test_unknown_combo_fatal() {
  local d; d=$(newdir)
  local out; out=$(run_resolver banana-pi sd some-machine "$d" 2>&1); local rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "unknown combo: non-zero exit"; else bad "unknown combo: expected non-zero"; fi
  if grep -q "banana-pi/sd" <<<"$out"; then ok "unknown combo: names bad key"; else bad "unknown combo: error lacks key"; fi
  rm -rf "$d"
}

# generated-nvme-img with a missing bundle is fatal at resolve time only via the
# workflow's own extraction guard, but the resolver still must NOT crash when
# the nvme .img itself is absent (it is generated later). Covered by
# test_jetson_nvme; here we assert the bundle-absent case yields an empty bundle
# without the resolver inventing the nvme image existence.
test_generated_nvme_bundle_absent() {
  local d M; d=$(newdir); M=jetson-agx-orin-devkit-nvme-wendyos
  # No files at all. recovery bundle glob finds nothing -> empty, but kind is
  # generated-nvme-img so the resolver does not treat the missing nvme .img as
  # fatal; it exits 0 and leaves the bundle empty for the workflow to guard.
  local out; out=$(run_resolver jetson-agx-orin nvme "$M" "$d"); local rc=$?
  assert_eq "generated-nvme bundle-absent: exits 0" 0 "$rc"
  assert_eq "generated-nvme bundle-absent: empty bundle" "" "$(field TEGRAFLASH_BUNDLE <<<"$out")"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# (c) Every device+storage combo in build.yml's matrix has a map entry.
# Hardcoded from build.yml's ALL_MATRIX — keep in sync if the matrix changes.
# ---------------------------------------------------------------------------
test_matrix_coverage() {
  local combos=(
    jetson-agx-thor/nvme
    jetson-agx-orin/nvme
    jetson-agx-orin/emmc
    jetson-orin-nano/nvme
    raspberry-pi-5/nvme
    raspberry-pi-5/sd
    raspberry-pi-4/sd
    raspberry-pi-3/sd
    generic-x86-64/disk
  )
  local c
  for c in "${combos[@]}"; do
    if [[ "$(jq -r --arg k "$c" 'has($k)' "$MAP")" == "true" ]]; then
      ok "map covers $c"
    else
      bad "map missing entry for $c"
    fi
  done
  # And no stray map entries beyond the matrix (guards against dead rows).
  local mapped; mapped=$(jq -r 'keys[]' "$MAP" | sort)
  local expected; expected=$(printf '%s\n' "${combos[@]}" | sort)
  if [[ "$mapped" == "$expected" ]]; then
    ok "map has exactly the matrix combos"
  else
    bad "map keys differ from matrix (map: $mapped)"
  fi
}

test_jetson_nvme
test_jetson_emmc
test_thor
test_tegraflash_zst
test_rpi_sdimg
test_rpi_wic
test_rpi5_pass_storage
test_x86_wic_disk
test_missing_bundle_fatal
test_missing_rpi_fatal
test_missing_x86_fatal
test_unknown_combo_fatal
test_generated_nvme_bundle_absent
test_matrix_coverage

echo
echo "===================="
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
