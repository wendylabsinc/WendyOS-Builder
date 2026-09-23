# BLE mesh peers scan and advertise while an LE CoC is active. The BlueZ/kernel
# default yielded a 420 ms supervision timeout on the Jetson centrals, which
# disconnected otherwise healthy links before the TLS handshake completed.
# BlueZ expresses this parameter in 10 ms units; 200 gives the tested 2 s.
do_install:append() {
    sed -i 's/^#ConnectionSupervisionTimeout=$/ConnectionSupervisionTimeout=200/' \
        ${D}${sysconfdir}/bluetooth/main.conf
    grep -qx 'ConnectionSupervisionTimeout=200' \
        ${D}${sysconfdir}/bluetooth/main.conf
}
