# Scarthgap path: prevent sysvinit from being backfilled into
# DISTRO_FEATURES via the legacy DISTRO_FEATURES_BACKFILL_CONSIDERED
# variable. Wrynose renamed this to DISTRO_FEATURES_OPTED_OUT — see
# systemd-features-modern.inc and the gating require in systemd.conf.
DISTRO_FEATURES_BACKFILL_CONSIDERED += " sysvinit"
