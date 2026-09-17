# Supply the HOMEPAGE that meta-tpm's own recipe QA flags as missing. meta-tpm
# opts its recipes into the oe-core metadata check with
#   WARN_QA:append:layer-tpm-layer = " patch-status missing-metadata"
# (meta-security/meta-tpm/conf/layer.conf:30), but its tpm2-tools recipe sets
# only SUMMARY and DESCRIPTION. Kept here so the upstream meta-security clone
# stays untouched.
#
# Collected only when the tpm-layer collection is present, via BBFILES_DYNAMIC
# in conf/layer.conf -- which is why this lives under dynamic-layers/ rather
# than recipes-tpm2/. meta-wendy is layered on every board, but meta-tpm is not
# (x86 and Tegra only), and a bbappend whose recipe does not exist anywhere is a
# hard error, not a no-op.
HOMEPAGE = "https://github.com/tpm2-software/tpm2-tools"
