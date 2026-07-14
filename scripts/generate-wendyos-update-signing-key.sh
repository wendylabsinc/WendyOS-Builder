#!/usr/bin/env bash
# Generate the wendyos-update OTA artifact signing keypair (finding C1b).
#
# BLOCKED ON UPSTREAM: the wendyos-update Go binary
# (github.com/wendylabsinc/wendyos-update) does NOT yet implement cryptographic
# artifact-signature verification — it only does structural validation + an
# install-time checksum. This keypair is builder-side scaffolding; it secures
# nothing until that binary verifies a detached signature against the baked
# public key (see docs/security/hardening-findings.md, finding C1b, step (1)).
#
# Mirrors scripts/generate-agent-signing-key.sh (finding C3). ECDSA P-256:
#
#   - PUBLIC key  -> committed to the image (recipes-core/wendyos-update/files/
#                    artifact-verify-key.pem; baked to
#                    /etc/wendyos-update/artifact-verify-key.pem).
#   - PRIVATE key -> kept OFFLINE / in CI secrets / an HSM. NEVER commit it. The
#                    OTA release pipeline signs each artifact with it:
#                      openssl dgst -sha256 -sign artifact-signing-key.priv.pem \
#                        -out <artifact>.sig <artifact>
#                    and publishes "<artifact>.sig" alongside the OTA payload.
#
# Fail-closed intent: once the Go binary verifies signatures, an unsigned or
# mismatched artifact must be REFUSED (no rootfs written) — never installed.
set -euo pipefail

OUT_DIR="${1:-.}"
PRIV="${OUT_DIR}/artifact-signing-key.priv.pem"
PUB="${OUT_DIR}/artifact-verify-key.pem"

if [ -e "${PRIV}" ] || [ -e "${PUB}" ]; then
    echo "refusing to overwrite existing ${PRIV} / ${PUB}" >&2
    exit 1
fi

umask 077
openssl ecparam -genkey -name prime256v1 -noout -out "${PRIV}"
openssl ec -in "${PRIV}" -pubout -out "${PUB}" 2>/dev/null
chmod 0644 "${PUB}"

echo "Private key (KEEP SECRET, do not commit): ${PRIV}"
echo "Public key  (commit to the image):        ${PUB}"
echo
echo "Next steps:"
echo "  1. Move ${PRIV} into CI secrets / an HSM and delete the local copy."
echo "  2. Replace recipes-core/wendyos-update/files/artifact-verify-key.pem with ${PUB}"
echo "     (or override it from a downstream layer via FILESEXTRAPATHS)."
echo "  3. BLOCKED: land detached-signature verification in the wendyos-update Go"
echo "     repo FIRST (it currently ignores the key)."
echo "  4. Sign every OTA artifact in the release pipeline:"
echo "       openssl dgst -sha256 -sign ${PRIV} -out <artifact>.sig <artifact>"
echo "     and publish <artifact>.sig next to the OTA payload."
