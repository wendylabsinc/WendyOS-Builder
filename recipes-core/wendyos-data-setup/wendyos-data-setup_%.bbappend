FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# When the TPM /data-encryption stack owns /data (WENDYOS_ENABLE_TPM=1), the shared
# data-crypt first-boot enroll grows + LUKS-formats the partition, and the crypttab
# unlock (systemd-cryptsetup@data) produces /dev/mapper/data. So on those builds we
# must NOT let wendyos-data-init format the RAW partition, and data.mount must target
# the unlocked mapper device instead of the raw partition. Gate off: everything here
# is inert and wendyos-data-setup behaves exactly as before (plain ext4 /data).

# 1) Do not auto-enable the raw-partition formatter when encryption owns /data
#    (data-crypt's enroll takes over the grow + format role).
SYSTEMD_SERVICE:${PN}:remove = "${@'wendyos-data-init.service' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"

# 2) Drop-in: point data.mount at /dev/mapper/data and order it after the unlock.
SRC_URI += "file://10-luks.conf"

do_install:append() {
    if [ "${WENDYOS_ENABLE_TPM}" = "1" ]; then
        install -d ${D}${systemd_system_unitdir}/data.mount.d
        install -m 0644 ${UNPACKDIR}/10-luks.conf ${D}${systemd_system_unitdir}/data.mount.d/10-luks.conf
    fi
}

FILES:${PN} += "${systemd_system_unitdir}/data.mount.d/10-luks.conf"
