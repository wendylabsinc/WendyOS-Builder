#!/usr/bin/env bash
# Security regression guardrails — plain bash, no framework (cf. resolve-artifacts.test.sh).
#
# Each assertion encodes the DESIRED SECURE STATE of the source tree, so it is
# RED until the matching finding in docs/security/hardening-findings.md is fixed.
# This is a deliberate, genuinely-red baseline: the suite exits non-zero while
# ANY finding is open, so no PR can forget an open item — the red check lists
# exactly what is left. Fixing a finding flips its assertion red -> green with
# no edit to this file. When the last finding closes, the whole suite is green
# (then promote security-ci to a required status check — see the spec).
#
# Spec: docs/superpowers/specs/2026-07-12-security-guardrails-design.md
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$ROOT" || exit 2

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

# -- helpers ----------------------------------------------------------------

# secure = PATTERN (ERE) appears in NONE of the given files. Missing files can't
# violate, so they pass. Used for "this dangerous thing must not be present".
assert_grep_absent() {
  local label=$1 pat=$2
  shift 2
  local existing=() f
  for f in "$@"; do [[ -e $f ]] && existing+=("$f"); done
  if [[ ${#existing[@]} -eq 0 ]]; then ok "$label"; return; fi
  if grep -El -- "$pat" "${existing[@]}" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi
}

# secure = PATTERN (ERE) appears in FILE.
assert_grep_present() {
  local label=$1 pat=$2 f=$3
  if [[ -e $f ]] && grep -Eq -- "$pat" "$f"; then ok "$label"; else bad "$label"; fi
}

# secure = git tracks NO file matching any of the given pathspec globs.
assert_no_tracked() {
  local label=$1
  shift
  local hits
  hits=$(git ls-files -- "$@" 2>/dev/null | head -5)
  if [[ -n "$hits" ]]; then
    bad "$label"
    while IFS= read -r h; do echo "         tracked: $h"; done <<<"$hits"
  else
    ok "$label"
  fi
}

# secure = git tracks AT LEAST ONE file matching any of the given globs.
assert_tracked_present() {
  local label=$1
  shift
  if git ls-files -- "$@" 2>/dev/null | grep -q .; then ok "$label"; else bad "$label"; fi
}

assert_path_present() {
  local label=$1 p=$2
  if [[ -e $p ]]; then ok "$label"; else bad "$label"; fi
}

# secure = the fstab entry for MNT (if any) carries nosuid AND nodev.
assert_mount_hardened() {
  local label=$1 fstab=$2 mnt=$3
  [[ -e $fstab ]] || { ok "$label (no fstab)"; return; }
  local line
  line=$(grep -E "[[:space:]]${mnt}[[:space:]]" "$fstab" | grep -vE '^[[:space:]]*#' | head -1)
  [[ -n "$line" ]] || { ok "$label (no $mnt entry)"; return; }
  if grep -q 'nosuid' <<<"$line" && grep -q 'nodev' <<<"$line"; then ok "$label"; else bad "$label"; fi
}

# secure = the DefaultBootPriority `data =` line has no usb/http/pxe token.
assert_bootorder_clean() {
  local label=$1 f=$2
  [[ -e $f ]] || { ok "$label (file gone)"; return; }
  local dl
  dl=$(grep -E '^[[:space:]]*data[[:space:]]*=' "$f" | head -1)
  if grep -qE '\b(usb|http|pxe)\b' <<<"$dl"; then bad "$label"; else ok "$label"; fi
}

echo "== Security guardrails (red until findings closed) =="

# ---------------------------------------------------------------------------
# C1a — Mender fully removed (OTA moved to wendyos-update)
# ---------------------------------------------------------------------------
assert_no_tracked "C1a: no Mender recipes/config/cert remain" '*mender*' '*Mender*'
assert_grep_absent "C1a: no MENDER_* vars in distro conf" 'MENDER_' conf/distro/wendyos.conf

# ---------------------------------------------------------------------------
# C1b — wendyos-update artifact signing (baked verify key + verification config)
# ---------------------------------------------------------------------------
assert_path_present "C1b: baked wendyos-update artifact verify key" \
  recipes-core/wendyos-update/files/artifact-verify-key.pem
assert_grep_present "C1b: recipe installs the verify key" \
  'artifact-verify-key' recipes-core/wendyos-update/wendyos-update_0.1.0.bb
# NOTE: must not match the existing boot-health "wendyos-update-verify.service".
# Artifact-signature config uses a distinct token (verify-key / signature / require_sig).
assert_grep_present "C1b: recipe installs a signature-verification config" \
  'verify-key|verify_key|signature|require_sig' recipes-core/wendyos-update/wendyos-update_0.1.0.bb

# ---------------------------------------------------------------------------
# C2 — Secure Boot enforced; no public EDK2 test certs
# ---------------------------------------------------------------------------
for mc in conf/machine/jetson-*-wendyos.conf; do
  assert_grep_present "C2: $(basename "$mc") enforces signed UEFI files" \
    'TEGRA_UEFI_USE_SIGNED_FILES[[:space:]]*=[[:space:]]*"true"' "$mc"
done
assert_grep_absent "C2: no EDK2 TestRoot/TestSub test certs committed" \
  'TestRoot|TestSub|edkii@tianocore' \
  meta-tegra-extensions/uefi-keys/generate-keys.sh \
  meta-tegra-extensions/recipes-bsp/uefi/files/UefiDefaultSecurityKeys.dts
assert_grep_absent "C2: key generation does not default to dev/test keys" \
  'DEV_KEYS:-1' meta-tegra-extensions/uefi-keys/generate-keys.sh

# ---------------------------------------------------------------------------
# C3 — The agent auto-updater must cryptographically verify the binary before
# install. Chosen remediation: keep the updater but make it FAIL-CLOSED — verify
# a detached signature against a baked public key (openssl) before chmod/install.
# Secure state = a verify key ships, the download script verifies a signature,
# and the recipe installs the key.
# ---------------------------------------------------------------------------
assert_path_present "C3: agent updater verify key is baked" \
  recipes-core/wendyos-agent/files/agent-verify-key.pem
assert_grep_present "C3: agent updater verifies a signature (openssl, fail-closed)" \
  'openssl dgst .*-verify' recipes-core/wendyos-agent/files/download-wendyos-agent.sh
assert_grep_present "C3: recipe installs the verify key" \
  'agent-verify-key' recipes-core/wendyos-agent/wendyos-agent_1.0.bb

# ---------------------------------------------------------------------------
# H1 — Fork-PR code must not run unguarded on the self-hosted builder
# ---------------------------------------------------------------------------
assert_grep_present "H1: build.yml guards the build job against fork PRs" \
  'head\.repo\.full_name == github\.repository' .github/workflows/build.yml

# ---------------------------------------------------------------------------
# H2 — Default 'wendy' user: no passwordless sudo, no baked shared password
# ---------------------------------------------------------------------------
assert_grep_absent "H2: no passwordless sudo for wendy" \
  'NOPASSWD' recipes-extended/wendyos-user/wendyos-user_1.0.bb
assert_grep_absent "H2: no baked shared password in useradd" \
  'USERADD_PARAM.*-p ' recipes-extended/wendyos-user/wendyos-user_1.0.bb

# ---------------------------------------------------------------------------
# H3 — A host firewall ruleset ships
# ---------------------------------------------------------------------------
assert_tracked_present "H3: a host firewall ruleset ships (nftables)" '*nftables*' '*.nft'

# ---------------------------------------------------------------------------
# H4 — Decision: LAN mDNS discovery is accepted by default (access is gated by
# the agent's mTLS, H3). The usb0-only FORTRESS lockdown must stay available:
# setting WENDYOS_MDNS_INTERFACES restricts advertisement via avahi's
# allow-interfaces. Guard that the lockdown mechanism remains wired.
# ---------------------------------------------------------------------------
assert_grep_present "H4: mDNS lockdown flag honored (avahi reads WENDYOS_MDNS_INTERFACES)" \
  'WENDYOS_MDNS_INTERFACES' recipes-connectivity/avahi/avahi_%.bbappend
assert_grep_present "H4: mDNS lockdown restricts interfaces (avahi allow-interfaces)" \
  'allow-interfaces' recipes-connectivity/avahi/avahi_%.bbappend

# ---------------------------------------------------------------------------
# H5 — Boot order excludes USB/HTTP/PXE
# ---------------------------------------------------------------------------
assert_bootorder_clean "H5: boot-priority excludes usb/http/pxe" \
  meta-tegra-extensions/recipes-bsp/tegra-bootcontrol-overlay/files/boot-priority.dtso
assert_bootorder_clean "H5: boot-priority-nvme excludes usb/http/pxe" \
  meta-tegra-extensions/recipes-bsp/tegra-bootcontrol-overlay/files/boot-priority-nvme.dtso

# ---------------------------------------------------------------------------
# H6 — Writable/removable partitions mounted nosuid,nodev
# ---------------------------------------------------------------------------
for fstab in recipes-core/base-files/files/rpi-wendy-fstab \
             recipes-core/base-files/files/rpi-wendy-mbr-fstab \
             recipes-core/base-files/files/rpi-fstab \
             recipes-core/base-files/files/rpi-mbr-fstab; do
  base=$(basename "$fstab")
  assert_mount_hardened "H6: $base /data nosuid,nodev" "$fstab" /data
  assert_mount_hardened "H6: $base /config nosuid,nodev" "$fstab" /config
  assert_mount_hardened "H6: $base /boot nosuid,nodev" "$fstab" /boot
done

# ---------------------------------------------------------------------------
# H8 — Dev container not privileged, no host net, no baked creds
# ---------------------------------------------------------------------------
assert_grep_absent "H8: dev container not run --privileged" \
  -- '--privileged' scripts/docker/docker-util.sh Makefile
assert_grep_absent "H8: dev container not run with host networking" \
  'network host|--net(work)?=host' scripts/docker/docker-util.sh Makefile
assert_grep_absent "H8: no passwordless sudo in dev image" \
  'NOPASSWD' scripts/docker/dockerfile
assert_grep_absent "H8: no baked password in dev image" \
  'chpasswd' scripts/docker/dockerfile

# ---------------------------------------------------------------------------
# H9 — Build-time toolchain downloads pinned + checksum-verified
# ---------------------------------------------------------------------------
assert_grep_present "H9: build-deps verify a download checksum" \
  'sha256sum -c|sha256sum --check|shasum -a 256 -c' scripts/install-build-deps.sh
assert_grep_absent "H9: Go toolchain pinned (no go.dev/VERSION latest)" \
  'go\.dev/VERSION' scripts/install-build-deps.sh

# ---------------------------------------------------------------------------
# M3 — Kernel hardening fragment with module signing
# ---------------------------------------------------------------------------
if git grep -qE 'CONFIG_MODULE_SIG_FORCE=y' -- '*.cfg' 2>/dev/null; then
  ok "M3: kernel enforces module signature (CONFIG_MODULE_SIG_FORCE)"
else
  bad "M3: kernel enforces module signature (CONFIG_MODULE_SIG_FORCE)"
fi

# ---------------------------------------------------------------------------
# M4 — No eval-based config expansion in the docker wrapper
# ---------------------------------------------------------------------------
assert_grep_absent "M4: no 'eval echo' in docker-util" \
  'eval echo' scripts/docker/docker-util.sh

# ---------------------------------------------------------------------------
# M5 — GCS token not passed on the command line
# ---------------------------------------------------------------------------
assert_grep_absent "M5: publisher token not passed via --access-token on argv" \
  'access-token "\$' .github/workflows/build.yml

# ---------------------------------------------------------------------------
# L1 — No committed prebuilt binary (CI rebuilds from source)
# ---------------------------------------------------------------------------
assert_no_tracked "L1: no committed publisher binary" 'tools/publisher/publisher'

# ---------------------------------------------------------------------------
# L3 — Dev base image pinned by digest
# ---------------------------------------------------------------------------
assert_grep_present "L3: dev base image pinned by digest (@sha256:)" \
  '@sha256:' scripts/docker/dockerfile

# ---------------------------------------------------------------------------
# LOCK-IN — already-secure state that must never regress (expected GREEN today)
# ---------------------------------------------------------------------------
assert_grep_present "LOCK: build-time agent fetch is sha256-pinned" \
  'SRC_URI\[agent.sha256sum\]' recipes-core/wendyos-agent/wendyos-agent_1.0.bb
assert_grep_present "LOCK: release build strips local login" \
  'disable_local_login' recipes-core/images/wendyos-image.bb
assert_grep_present "LOCK: security-review refuses fork PRs" \
  'head\.repo\.full_name == github\.repository' .github/workflows/security-review.yml
assert_grep_present "LOCK: security-review wraps untrusted PR content" \
  'untrusted_pr_content' .github/workflows/security-review.yml
assert_grep_present "LOCK: SSHD is an opt-in image feature (not on by default)" \
  'WENDYOS_SSHD' recipes-core/images/wendyos-image.bb

# ---------------------------------------------------------------------------
echo
echo "guardrails: ${pass} ok, ${fail} FAIL"
if [[ $fail -ne 0 ]]; then
  echo "RED baseline — open findings remain (docs/security/hardening-findings.md)."
  exit 1
fi
echo "All security guardrails green."
