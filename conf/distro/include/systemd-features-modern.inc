# Modern (post-scarthgap) path: DISTRO_FEATURES_BACKFILL_CONSIDERED was
# renamed to DISTRO_FEATURES_OPTED_OUT in wrynose oe-core. Setting the
# old name on wrynose errors via BB_RENAMED_VARIABLES; scarthgap doesn't
# know about the new name. Series-gated from systemd.conf.
DISTRO_FEATURES_OPTED_OUT += " sysvinit"
