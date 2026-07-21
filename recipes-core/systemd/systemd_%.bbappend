# Disable polkit support in systemd
# We enable polkit distro feature for rtkit, but systemd doesn't actually need
# polkit support compiled in. Disabling it avoids build issues with polkitd user
# not existing during systemd's install phase.
#
# Note: This only disables PolicyKit integration in systemd itself. The polkit
# daemon will still run on the target system for rtkit and other services.

PACKAGECONFIG:remove = "polkit"

# Disable debug source package splitting to avoid pseudo uid lookup failures.
# do_package hardlinks source files (owned by uid 1000 / build user) into PKGD.
# OEOuthashBasic then calls getpwuid(1000) via pseudo, which redirects to the
# target rootfs /etc/passwd — which has no uid 1000 — causing a KeyError fatal.
# Debug packages are not deployed to the target image, so this has no runtime impact.
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"

# RPi5-specific systemd extensions — isolated so Tegra/QEMU builds are unaffected
require ${@'rpi-systemd.inc' if 'rpi' in d.getVar('MACHINEOVERRIDES').split(':') else ''}

# Enable systemd's TPM2 + cryptsetup support for the /data encryption stack when
# WENDYOS_ENABLE_TPM=1 (shared across boards; the /data enroll recipe is
# data-crypt). The tpm2 PACKAGECONFIG pulls in libtss2 from meta-security/meta-tpm,
# so a board turning this on must also layer meta-tpm (x86 does; other boards wire
# it as needed). Inert — stock systemd — when the gate is off, the default on every
# board.
PACKAGECONFIG:append = "${@' tpm2 cryptsetup' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"
