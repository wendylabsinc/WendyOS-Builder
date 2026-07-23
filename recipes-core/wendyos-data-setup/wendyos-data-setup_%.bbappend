FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# When the TPM /data-encryption stack owns /data (WENDYOS_ENABLE_TPM=1), the shared
# data-crypt first-boot enroll grows + LUKS-formats the partition, and the crypttab
# unlock (systemd-cryptsetup@data) produces /dev/mapper/data. So on those builds we
# must NOT let wendyos-data-init format the RAW partition, and data.mount must target
# the unlocked mapper device instead of the raw partition. Gate off (the default on
# every board): everything here is inert and wendyos-data-setup behaves exactly as
# before (plain ext4 /data). Note the gate only reaches this recipe when set in
# local.conf (config scope); the ?= defaults live in image includes.

# 1) Do not auto-enable the raw-partition formatter when encryption owns /data
#    (data-crypt's enroll takes over the grow + format role).
SYSTEMD_SERVICE:${PN}:remove = "${@'wendyos-data-init.service' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"

# 2) Replace data.mount wholesale with the LUKS variant (mapper device + unlock
#    dependency). It must be a full unit override, not a drop-in: the base
#    data.mount hard-Requires wendyos-data-init.service and systemd drop-ins can
#    only ADD dependencies, never remove them (systemd.unit(5)); a drop-in would
#    leave that Requires= in place, still running the raw-partition mkfs and racing
#    data-enroll's luksFormat ("device in use", seen on-device 2026-07-22).
SRC_URI += "file://data-luks.mount"

do_install:append() {
    if [ "${WENDYOS_ENABLE_TPM}" = "1" ]; then
        install -m 0644 ${UNPACKDIR}/data-luks.mount ${D}${systemd_system_unitdir}/data.mount
    fi
}

