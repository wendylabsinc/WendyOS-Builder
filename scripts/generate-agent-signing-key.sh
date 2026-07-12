#!/usr/bin/env bash
# Generate the wendy-agent auto-updater signing keypair (finding C3).
#
# The auto-updater (recipes-core/wendyos-agent/files/download-wendyos-agent.sh)
# verifies a detached signature over each downloaded release against a baked-in
# PUBLIC key. This script generates the ECDSA P-256 keypair:
#
#   - PUBLIC key  -> committed to the image (recipes-core/wendyos-agent/files/
#                    agent-verify-key.pem, or override WENDYOS_AGENT_VERIFY_KEY).
#   - PRIVATE key -> kept OFFLINE / in CI secrets. NEVER commit it. The agent
#                    release pipeline signs each asset with it:
#                      openssl dgst -sha256 -sign agent-signing-key.priv.pem \
#                        -out <asset>.tar.gz.sig <asset>.tar.gz
#                    and publishes "<asset>.tar.gz.sig" alongside the tarball.
#
# The updater is FAIL-CLOSED: until releases are signed with the matching private
# key, devices simply won't auto-update (they never install an unverified binary).
set -euo pipefail

OUT_DIR="${1:-.}"
PRIV="${OUT_DIR}/agent-signing-key.priv.pem"
PUB="${OUT_DIR}/agent-verify-key.pem"

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
echo "  2. Replace recipes-core/wendyos-agent/files/agent-verify-key.pem with ${PUB}"
echo "     (or point WENDYOS_AGENT_VERIFY_KEY at it)."
echo "  3. Sign every agent release asset:"
echo "       openssl dgst -sha256 -sign ${PRIV} -out <asset>.sig <asset>"
echo "     and publish <asset>.sig next to the tarball in the GitHub release."
