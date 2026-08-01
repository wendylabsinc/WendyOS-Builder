# Supply the HOMEPAGE that meta-tpm's own recipe QA flags as missing. See the
# tpm2-tools bbappend next to this one for the full explanation; in short,
# meta-tpm opts into the oe-core metadata check via
#   WARN_QA:append:layer-tpm-layer = " patch-status missing-metadata"
# (meta-security/meta-tpm/conf/layer.conf:30) but does not set HOMEPAGE itself.
#
# Under dynamic-layers/ so it is only collected when the tpm-layer collection is
# present (BBFILES_DYNAMIC in conf/layer.conf). Boards without meta-tpm have no
# tpm2-tss recipe, and an unmatched bbappend is a hard error.
HOMEPAGE = "https://github.com/tpm2-software/tpm2-tss"
