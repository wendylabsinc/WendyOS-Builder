# dnsmasq configuration for NetworkManager integration.
# Both mesh sharing and NM's USB method=shared mode spawn scoped instances.
# DBus support is required for NM to manage its instance.
PACKAGECONFIG:append = " dbus"

# Disable the system-wide dnsmasq.service so it does not conflict with
# the NM-managed dnsmasq instance
SYSTEMD_AUTO_ENABLE = "disable"

# Upstream assumes a system-wide dnsmasq listener and disables resolved's
# loopback stub. Our instances bind only their owned mesh/USB addresses, so
# keep the stub available for per-link DNS routing on borrowers.
do_install:append() {
    rm -f ${D}${sysconfdir}/systemd/resolved.conf.d/dnsmasq-resolved.conf
}
