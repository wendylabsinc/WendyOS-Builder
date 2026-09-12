# Publish the driver add-on compatibility level. systemd only compares SYSEXT_LEVEL when
# both the host and the add-on declare one; without this field it falls back to VERSION_ID
# and every add-on stops merging on the next patch release.
SYSEXT_LEVEL = "${WENDYOS_SYSEXT_LEVEL}"
OS_RELEASE_FIELDS:append = " SYSEXT_LEVEL"
OS_RELEASE_UNQUOTED_FIELDS:append = " SYSEXT_LEVEL"
