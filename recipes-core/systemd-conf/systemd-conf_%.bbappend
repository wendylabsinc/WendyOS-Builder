
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

inherit ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'systemd', '', d)}

# Add persistent journal configuration if enabled
SRC_URI += " \
    ${@'file://journald-persistent.conf file://var-log.mount' if d.getVar('WENDYOS_PERSIST_JOURNAL_LOGS') == '1' else ''} \
    "

# --- network-online.target provider hygiene (net-manager aware) ---
# Only one wait-online service should gate network-online.target. We pick it
# based on the active net manager so a future switch flips the policy
# automatically (see the shipped wendyos-network-online.preset /
# networkd-wait-online-any.conf for the full rationale):
#   - networkmanager:    disable systemd-networkd-wait-online (NM provides it)
#   - systemd-networkd:  make networkd's wait-online succeed on --any link
WENDYOS_NET_MANAGER ?= "${@d.getVar('VIRTUAL-RUNTIME_net_manager') or ''}"

# Stop systemd-networkd claiming ethernet links when NetworkManager owns the
# network. This recipe's own dhcp-ethernet PACKAGECONFIG installs
# 80-wired.network, which matches Type=ether with DHCP=yes, UseMTU=yes and
# RouteMetric=10 -- so while it is present EVERY ethernet link is configured
# twice, once by networkd and once by NM.
#
# Measured on an AGX Orin, 2026-08-23: two DHCP clients holding separate leases
# on eth0, two default routes (metric 10 networkd, 100 NM via
# 99-interface-metrics.conf), and networkd re-asserting link settings behind
# anything else that touched them -- it reverted a runtime MTU change within
# ~2s, every time, which is how this was found.
#
# Removing the file rather than disabling the daemon is deliberate. It is the
# narrower fix: networkd keeps running and its other functions are untouched,
# it needs no preset gymnastics, and it does not re-litigate ddd01493 (which
# removed the networkd package outright and was reverted by 5e5881df with no
# stated reason). Verified on-device with the file moved aside: networkd reports
# eth0 as "routable (unmanaged)", one default route, one lease, and an
# `ip link set mtu` that holds. Time sync still works, falling back to
# timesyncd's compiled-in servers now that no DHCP option 42 reaches it.
#
# Disabling the daemon instead would need BOTH a rule in a preset file sorting
# before 90-systemd.preset AND SYSTEMD_AUTO_ENABLE:systemd-networkd = "disable",
# because preset-all and the package postinst enable it independently.
PACKAGECONFIG:remove = "${@'dhcp-ethernet' if d.getVar('WENDYOS_NET_MANAGER') == 'networkmanager' else ''}"

SRC_URI += " \
    ${@'file://wendyos-network-online.preset' if d.getVar('WENDYOS_NET_MANAGER') == 'networkmanager' else ''} \
    ${@'file://networkd-wait-online-any.conf' if d.getVar('WENDYOS_NET_MANAGER') == 'systemd-networkd' else ''} \
    "

# Enable var-log.mount unit when journal persistence is enabled
SYSTEMD_SERVICE:${PN} += "${@'var-log.mount' if d.getVar('WENDYOS_PERSIST_JOURNAL_LOGS') == '1' else ''}"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install:append() {
    if [ "${WENDYOS_PERSIST_JOURNAL_LOGS}" = "1" ]; then
        # Install persistent journal configuration
        # systemd-journald will automatically create /var/log/journal
        # with correct permissions when Storage=persistent is set
        install -D -m0644 ${UNPACKDIR}/journald-persistent.conf ${D}${systemd_unitdir}/journald.conf.d/10-wendyos-persistent.conf

        # Install var-log.mount unit to bind mount /data/log to /var/log
        # The x-systemd.mkdir option auto-creates /data/log if needed
        install -D -m0644 ${UNPACKDIR}/var-log.mount ${D}${systemd_system_unitdir}/var-log.mount
    fi

    # network-online.target provider hygiene (see the shipped files)
    if [ "${WENDYOS_NET_MANAGER}" = "networkmanager" ]; then
        install -D -m0644 ${UNPACKDIR}/wendyos-network-online.preset \
            ${D}${systemd_unitdir}/system-preset/15-wendyos-network-online.preset

        # MASK networkd's wait-online, because disabling it cannot work: it is
        # listed in Also= on systemd-networkd.service, so enabling that service
        # re-enables this one whatever the preset says. Measured on an AGX Orin
        # 2026-08-23: it burns its full 119s timeout and then fails, because with
        # networkd no longer configuring ethernet (see the dhcp-ethernet removal
        # above) there is no managed link that can ever come online. It is
        # Before=network-online.target, so it also delays the one unit that wants
        # that target, wendyos-agent-updater.service.
        #
        # NetworkManager-wait-online.service provides network-online.target on
        # this image, so nothing is lost.
        install -d ${D}${sysconfdir}/systemd/system
        ln -sf /dev/null ${D}${sysconfdir}/systemd/system/systemd-networkd-wait-online.service
    elif [ "${WENDYOS_NET_MANAGER}" = "systemd-networkd" ]; then
        install -D -m0644 ${UNPACKDIR}/networkd-wait-online-any.conf \
            ${D}${systemd_system_unitdir}/systemd-networkd-wait-online.service.d/10-wendyos-any.conf
    fi
}

# Package the net-online policy files (paths absent for the other manager are
# harmless to list).
FILES:${PN} += " \
    ${systemd_unitdir}/system-preset/15-wendyos-network-online.preset \
    ${systemd_system_unitdir}/systemd-networkd-wait-online.service.d \
    ${sysconfdir}/systemd/system/systemd-networkd-wait-online.service \
    "
