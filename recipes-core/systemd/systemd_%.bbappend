# Disable polkit support in systemd
# We enable polkit distro feature for rtkit, but systemd doesn't actually need
# polkit support compiled in. Disabling it avoids build issues with polkitd user
# not existing during systemd's install phase.
#
# Note: This only disables PolicyKit integration in systemd itself. The polkit
# daemon will still run on the target system for rtkit and other services.

# NetworkManager is the sole net/DNS manager on this distro:
#   - networkd: not used (no .network files, NM manages all interfaces)
#   - resolved + nss-resolve: not used (NM owns /etc/resolv.conf via rc-manager=file)
PACKAGECONFIG:remove = "polkit networkd resolved nss-resolve"

# Strip the dangling /etc/resolv.conf symlink artefacts the upstream systemd
# recipe injects when 'resolved' PACKAGECONFIG is disabled. The recipe assumes
# you'll re-enable resolved later via tmpfiles; this distro doesn't — NM
# (rc-manager=file) writes /etc/resolv.conf directly.
do_install:append() {
    if [ -f ${D}${exec_prefix}/lib/tmpfiles.d/etc.conf ]; then
        sed -i '\|^L! /etc/resolv\.conf|d' ${D}${exec_prefix}/lib/tmpfiles.d/etc.conf
    fi
    rm -f ${D}${sysconfdir}/resolv-conf.systemd
}

# Disable debug source package splitting to avoid pseudo uid lookup failures.
# do_package hardlinks source files (owned by uid 1000 / build user) into PKGD.
# OEOuthashBasic then calls getpwuid(1000) via pseudo, which redirects to the
# target rootfs /etc/passwd — which has no uid 1000 — causing a KeyError fatal.
# Debug packages are not deployed to the target image, so this has no runtime impact.
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"

# RPi5-specific systemd extensions — isolated so Tegra/QEMU builds are unaffected
require ${@'rpi-systemd.inc' if 'rpi' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
