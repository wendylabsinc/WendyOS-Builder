# Disable polkit support in systemd
# We enable polkit distro feature for rtkit, but systemd doesn't actually need
# polkit support compiled in. Disabling it avoids build issues with polkitd user
# not existing during systemd's install phase.
#
# Note: This only disables PolicyKit integration in systemd itself. The polkit
# daemon will still run on the target system for rtkit and other services.

PACKAGECONFIG:remove = "polkit"

# Enable PAM support. user@.service (PAMName=systemd-user) needs pam_systemd.so
# and /etc/pam.d/systemd-user to set $XDG_RUNTIME_DIR when starting a user
# manager instance — without it, user@<uid>.service fails outright ("Trying to
# run as user instance, but $XDG_RUNTIME_DIR is not set") even though
# user-runtime-dir@<uid>.service already created the runtime directory itself;
# that oneshot only creates the directory, it can't inject environment into a
# different unit's process. This breaks every rootless per-user session on the
# image (e.g. audio-config's PipeWire/WirePlumber session for the wendy user),
# not just lingering ones. 'pam' isn't in DISTRO_FEATURES (unlike polkit
# above), so it's not part of systemd's default PACKAGECONFIG; the module and
# PAM config are both already covered by the upstream recipe's FILES:${PN}, so
# no extra install step is needed here.
PACKAGECONFIG:append = " pam"

# Disable debug source package splitting to avoid pseudo uid lookup failures.
# do_package hardlinks source files (owned by uid 1000 / build user) into PKGD.
# OEOuthashBasic then calls getpwuid(1000) via pseudo, which redirects to the
# target rootfs /etc/passwd — which has no uid 1000 — causing a KeyError fatal.
# Debug packages are not deployed to the target image, so this has no runtime impact.
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"

# systemd-sysext is off by default in oe-core and is what merges driver add-ons onto /usr.
# Keyed on the feature rather than a machine family, since nothing about it is board-specific.
PACKAGECONFIG:append = "${@' sysext' if d.getVar('WENDYOS_DRIVER_EXTENSIONS') == '1' else ''}"

# RPi5-specific systemd extensions — isolated so Tegra/QEMU builds are unaffected
require ${@'rpi-systemd.inc' if 'rpi' in d.getVar('MACHINEOVERRIDES').split(':') else ''}

# systemd's two security PACKAGECONFIGs follow different gates. tpm2 belongs to the
# TPM stack itself; cryptsetup belongs to /data encryption, which is what needs
# systemd-cryptenroll and the boot-time systemd-cryptsetup@data (both ship in the
# systemd-crypt package). The tpm2 PACKAGECONFIG pulls in libtss2 from
# meta-security/meta-tpm, so a board turning it on must also layer meta-tpm (x86
# does; other boards wire it as needed). Each is inert — stock systemd — when its
# own gate is off. At the default both are on, giving the same set as before.
PACKAGECONFIG:append = "${@' tpm2' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"
PACKAGECONFIG:append = "${@' cryptsetup' if d.getVar('WENDYOS_DATA_ENCRYPTED') == '1' else ''}"
