
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
    "
