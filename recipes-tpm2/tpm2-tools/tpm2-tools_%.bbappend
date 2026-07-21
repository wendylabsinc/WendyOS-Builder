# Supply the HOMEPAGE that blacksail oe-core's recipe-QA flags as missing on the
# meta-tpm recipe (missing-metadata warning). Kept in our layer so the upstream
# meta-security clone stays untouched. Inert unless tpm2-tools is built
# (WENDYOS_ENABLE_TPM).
HOMEPAGE = "https://github.com/tpm2-software/tpm2-tools"
