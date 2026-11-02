# BLE mesh peers scan and advertise while an LE CoC is active. The BlueZ/kernel
# default yielded a 420 ms supervision timeout on the Jetson centrals, which
# disconnected otherwise healthy links before the TLS handshake completed.
# BlueZ expresses this parameter in 10 ms units; 200 gives the tested 2 s.
do_install:append() {
    sed -i 's/^#ConnectionSupervisionTimeout=$/ConnectionSupervisionTimeout=200/' \
        "${D}${sysconfdir}/bluetooth/main.conf"
    grep -qx 'ConnectionSupervisionTimeout=200' \
        "${D}${sysconfdir}/bluetooth/main.conf" || \
        bbfatal "BlueZ main.conf did not accept ConnectionSupervisionTimeout=200; check the upstream template"

    # Incoming phones are clients of Wendy's setup/management service. Reverse
    # GATT discovery reads protected phone characteristics and triggers SMP
    # pairing; on a headless, non-pairable board BlueZ rejects that pairing and
    # disconnects the otherwise working L2CAP setup channel. Keep discovery for
    # connections initiated by Wendy (including paired BLE peripherals), but do
    # not automatically inspect the services of incoming clients.
    sed -i 's/^#ReverseServiceDiscovery = true$/ReverseServiceDiscovery = false/' \
        "${D}${sysconfdir}/bluetooth/main.conf"
    grep -qx 'ReverseServiceDiscovery = false' \
        "${D}${sysconfdir}/bluetooth/main.conf" || \
        bbfatal "BlueZ main.conf did not accept ReverseServiceDiscovery=false; check the upstream template"

    # Battery monitoring reads protected peer GATT characteristics and can
    # trigger bonding, then tear down an otherwise unpaired LE CoC connection.
    # Disabling reverse discovery does not cover links Wendy opens to phones.
    # BLE accessories lose Battery1. Fail rather than overwrite new daemon args.
    bluetooth_service="${D}${systemd_system_unitdir}/bluetooth.service"
    grep -Eq '^ExecStart=[^[:space:]]*/bluetoothd$' "$bluetooth_service" || \
        bbfatal "Unexpected BlueZ ExecStart; preserve its arguments when disabling the battery plugin"
    sed -i '/^ExecStart=/s/$/ --noplugin=battery/' "$bluetooth_service"
}
