# BlueZ 5.87 passes a UUID string as queue_find's callback and crashes when
# processing service advertisements during UUID-filtered discovery (WDY-4005).
# Keep the backport version-specific so a future upstream release is not
# patched a second time.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://0001-adapter-Fix-crash-on-UUID-discovery-filter-match.patch"
PR:append = ".wendy1"
