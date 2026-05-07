FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://radvd.conf"

inherit systemd

do_install:append() {
    # Install our custom radvd configuration
    install -d ${D}${sysconfdir}
    install -m 0644 ${UNPACKDIR}/radvd.conf ${D}${sysconfdir}/radvd.conf

    # Create systemd service if not provided by the recipe
    if [ ! -f ${D}${systemd_unitdir}/system/radvd.service ]; then
        install -d ${D}${systemd_unitdir}/system
        cat > ${D}${systemd_unitdir}/system/radvd.service <<EOF
[Unit]
Description=IPv6 Router Advertisement Daemon
After=network-online.target wendyos-usbgadget-prepare.service
Wants=network-online.target
Requires=wendyos-usbgadget-prepare.service

[Service]
Type=forking
ExecStartPre=/bin/sh -c 'test -e /sys/class/net/usb0 || sleep 2'
ExecStart=/usr/sbin/radvd -C /etc/radvd.conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    fi
}

SYSTEMD_SERVICE:${PN} = "radvd.service"
SYSTEMD_AUTO_ENABLE = "enable"

# Runtime dependencies
RDEPENDS:${PN} += "kernel-module-ipv6"