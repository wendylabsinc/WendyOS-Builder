# Replace the common password-changing stack in the package that owns it.
FILESEXTRAPATHS:prepend:class-target := "${THISDIR}/files:"
RDEPENDS:${PN}-runtime:append:class-target = " libpwquality"
