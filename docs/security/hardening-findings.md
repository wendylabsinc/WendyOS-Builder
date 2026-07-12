# WendyOS Builder — Security Hardening Findings

Audit date: **2026-07-12**. Scope: the Yocto image builder (recipes, distro/machine
config, CI/CD, boot chain, build tooling). The `wendy-agent` binary is fetched
pre-built from another repo, so its internal gRPC auth/mTLS is **out of scope for
this tree** — findings that depend on it are marked *manual-verify*.

Each finding has a **Guard** column:

- `test` — encoded as an assertion in `scripts/security-guardrails.test.sh`
  (regression fails CI). The assertion asserts the **desired secure state**, so it
  is **red** until the finding is fixed. This is our TDD checklist.
- `manual` — cannot be tested in this repo (out-of-tree binary, or lives in a GCP
  console). Tracked here; verify by hand.
- `lock-in` — the secure state already exists; the test exists only to prevent a
  silent regression.

Status: 🔴 vulnerable (test red) · 🟢 fixed (test green) · 🔵 verify externally.

> **OTA correction (2026-07-12):** There is **no Mender server** — the project moved
> to `wendyos-update`. So the original "Mender demo cert / unsigned artifact"
> criticals are re-scoped to: **(a) remove Mender entirely**, and **(b) give
> `wendyos-update` a real CA trust anchor + artifact signature verification.**

---

## Critical

| ID | Finding | Where | Guard | Status |
|----|---------|-------|-------|--------|
| C1a | **Remove Mender entirely** — dead OTA stack still ships recipes, config, and a public demo `server.crt`. | `conf/distro/include/mender*.inc`, `conf/distro/wendyos.conf` (`MENDER_*`), `meta-tegra-extensions*/recipes-mender/**`, `.../mender/files/server.crt` | test | 🔴 |
| C1b | **`wendyos-update` has no artifact signature verification and no pinned CA** — an attacker who can serve/redirect updates can push an arbitrary rootfs → remote root. | `recipes-core/wendyos-update/wendyos-update_0.1.0.bb` (+ its client config) | test | 🔴 |
| C2 | **Secure Boot disabled on every Jetson**; the "enable" path enrolls **public EDK2 TestRoot/TestSub** certs. | `conf/machine/jetson-*-wendyos.conf` (`TEGRA_UEFI_USE_SIGNED_FILES="false"`); `meta-tegra-extensions/uefi-keys/generate-keys.sh` (`DEV_KEYS=1`); `meta-tegra-extensions/recipes-bsp/uefi/files/UefiDefaultSecurityKeys.dts` | test (config) + manual (fuse burn) | 🔴 |
| C3 | **Agent auto-updater installed the root control-plane binary with no signature/checksum check.** **FIXED (builder side):** the updater now verifies a detached ECDSA signature against a baked public key (`openssl dgst -verify`) before install, **fail-closed** — a missing key/sig/openssl or a mismatch aborts the update and leaves the running binary untouched. **Cross-repo TODO:** the agent release pipeline must sign each asset (`<asset>.sig`) with the private half (CI secrets / HSM); until then devices simply won't auto-update. Ship a real key via `WENDYOS_AGENT_VERIFY_KEY` (dev key committed; regen with `scripts/generate-agent-signing-key.sh`). | `recipes-core/wendyos-agent/files/download-wendyos-agent.sh`, `.../agent-verify-key.pem`, `.../wendyos-agent_1.0.bb` | test | 🟢 |

> **C1b BLOCKER (verified 2026-07-12):** the pinned `wendyos-update` binary
> (`github.com/wendylabsinc/wendyos-update`@`20ec14e`, per its `docs/cli-contract.md`)
> supports only *structural* validation + a checksum on install/pack — **no
> cryptographic artifact signing** (no verify key, signature, or public-key
> config). C1b is therefore a **cross-repo** change, in this order: **(1)**
> implement detached-signature verification in the `wendyos-update` Go repo
> (verify against a baked public key; refuse unsigned/mismatched artifacts);
> **(2)** builder bakes the public key at `/etc/wendyos-update/artifact-verify-key.pem`
> + a `config.json` requiring verification (this repo — turns the C1b guardrail
> green); **(3)** release CI signs artifacts with the private key (CI secrets /
> offline). Doing (2) alone is security theater — the binary would ignore the
> key. Guardrail stays RED until (1)+(2) land.

## High

| ID | Finding | Where | Guard | Status |
|----|---------|-------|-------|--------|
| H1 | **Fork-PR code runs on the persistent self-hosted builder** with a shared **writable** sstate/downloads cache → release-image cache poisoning. No same-repo guard on the `build` job. | `.github/workflows/build.yml` (`on: pull_request`, job `build` `if:`, `runs-on: self-hosted`, cache symlink) | test (workflow lint) | 🟢 |
| H2 | **Default `wendy`/`wendy` user with `NOPASSWD: ALL`** — fleet-wide static credential; becomes remote root the moment `WENDYOS_SSHD=1`. | `recipes-extended/wendyos-user/wendyos-user_1.0.bb` | test | 🔴 |
| H3 | **No host firewall**; wendy-agent gRPC (`:50051`) exposure rests entirely on the out-of-tree binary's bind/mTLS. | absence of nftables ruleset; `wendyos-agent.service` | test (firewall present) + manual (agent mTLS) | 🔴 / 🔵 |
| H4 | **mDNS advertises control-plane port + device UUID on ALL interfaces** despite a comment claiming `usb0`-only. | `conf/distro/wendyos.conf` (`WENDYOS_MDNS_INTERFACES ?= ""`); `recipes-connectivity/avahi/avahi_%.bbappend` | test | 🔴 |
| H5 | **Boot order allows USB/HTTP/PXE** — physical/LAN boot of attacker code (compounds C2). | `meta-tegra-extensions/recipes-bsp/tegra-bootcontrol-overlay/files/boot-priority*.dtso` | test | 🔴 |
| H6 | **No rootfs integrity (no dm-verity), rootfs mounted `rw`; `/data`,`/config`,`/boot` mounted without `nosuid,nodev,noexec`.** | `recipes-core/base-files/files/*fstab` | test (mount flags) | 🔴 |
| H7 | **Data at rest is plaintext** (WiFi PSKs, identity); OP-TEE storage is REE-FS with no RPMB anti-rollback. | no LUKS/dm-crypt/fscrypt in tree; `recipes-core/systemd-mount-tee/**` | manual (design change) | 🔵 |
| H8 | **Dev container runs `--privileged --network host`** with passwordless sudo + baked `dev:wendyos` password. | `scripts/docker/dockerfile`, `scripts/docker/docker-util.sh`, `Makefile` | test | 🔴 |
| H9 | **Build-time toolchain downloads unverified/unpinned** (Go "latest", AWS CLI, s5cmd, fzf HEAD). | `scripts/install-build-deps.sh`, `scripts/docker/dockerfile` | test | 🔴 |
| H10 | **GCP Workload Identity trust condition unverifiable in-repo** — must pin `assertion.repository`. | GCP console (WIF provider) | manual | 🔵 |

## Medium

| ID | Finding | Where | Guard | Status |
|----|---------|-------|-------|--------|
| M1 | **No OTA rollback/downgrade protection** (monotonic version gate). | `wendyos-update` client | test (once C1b lands) | 🔴 |
| M2 | **`WENDYOS_DEV_LOGIN=1` restores empty-root-password + root login + getty** on publicly-installable PR images. Ensure it can never ride into release/nightly; default off. | `recipes-core/images/wendyos-image.bb` | lock-in test | 🟢 (guard) |
| M3 | **No kernel hardening fragments / no module signing**; Jetson serial console always on. | `recipes-kernel/**`, `wendyos-image.bb:63` | test | 🔴 |
| M4 | **`eval echo` on a cwd-derived path** (config parse). | `scripts/docker/docker-util.sh:55-62` | test | 🟢 |
| M5 | **GCS access token passed on argv** (`--access-token`) — visible in `ps`/logs. | `.github/workflows/build.yml`, `tools/publisher/upload_and_manifest.go` | test | 🟢 |

## Low / hygiene

| ID | Finding | Where | Guard | Status |
|----|---------|-------|-------|--------|
| L1 | **22 MB stale Mach-O `publisher` binary committed** (CI rebuilds from source; never executed by CI). | `tools/publisher/publisher` | test (no committed binary) | 🟢 |
| L2 | `eval`-built `sudo` strings; predictable-name tmpfile in `oe4t-tegraflash-deploy`. | `scripts/run-qemu.sh`, `scripts/manage-*`, `scripts/oe4t-tegraflash-deploy` | — | 🔵 |
| L3 | Base image pinned to mutable `ubuntu:24.04` tag (not digest). | `scripts/docker/dockerfile` | test | 🔴 |
| L4 | `mender-secrets.inc` tracked in git (footgun if a real tenant token is filled in) — removed with C1a. | `conf/distro/include/mender-secrets.inc` | folded into C1a | 🔴 |

## Confirmed-good (lock-in only — do not regress)

- Fortress login hardening: root locked (`root:*:`), no getty/serial/autovt on release, SSH off by default, gRPC-only access (`wendyos-image.bb:54-88`).
- Build-time agent fetch is `sha256`-pinned; upstream repos pinned to immutable SRCREVs over HTTPS.
- `security-review.yml` well-built: same-repo-only, `pull_request` (not `_target`), prompt-injection guard.
- Publisher path validation rejects `/`, `..`, NUL, CR/LF; per-artifact SHA256.
- UEFI shell excluded from boot priority; RPi U-Boot autoboot disabled; reviewed kernel patches are CVE fixes.
