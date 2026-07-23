SUMMARY = "Systemd mount unit for persistent OP-TEE secure storage"
DESCRIPTION = "Bind mounts /var/lib/tee from /data/tee so OP-TEE secure storage \
(PKCS#11 tokens, device keys, certificates) persists across A/B OTA updates. \
Without this, the default /var/lib/tee on the rootfs would be wiped on every A/B \
partition switch, destroying the device's OP-TEE-backed cryptographic identity."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://var-lib-tee.mount \
    file://var-lib-tee-tpm.mount \
    "
S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "var-lib-tee.mount"
SYSTEMD_AUTO_ENABLE = "enable"

# With the TPM /data-encryption stack on (WENDYOS_ENABLE_TPM=1), OP-TEE secure
# storage cannot live on /data -- the fTPM's NV would sit inside the volume the
# fTPM must unlock (circular, see the -tpm unit header). Install the /config-backed
# variant AS var-lib-tee.mount in that case; a drop-in cannot do this because the
# base unit's RequiresMountsFor=/data dependency cannot be removed by drop-ins.
FTPM_MOUNT_VARIANT = "${@'var-lib-tee-tpm.mount' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else 'var-lib-tee.mount'}"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/${FTPM_MOUNT_VARIANT} ${D}${systemd_system_unitdir}/var-lib-tee.mount
}

FILES:${PN} += "${systemd_system_unitdir}/var-lib-tee.mount"

RDEPENDS:${PN} = "systemd"
