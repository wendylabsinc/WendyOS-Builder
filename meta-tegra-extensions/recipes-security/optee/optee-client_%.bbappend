FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# fTPM boot sequencing for the /data encryption stack (WENDYOS_ENABLE_TPM=1).
# Three pieces, all needed so the fTPM is persistent AND ready before the /data
# unlock (validated on Thor, see docs/plans/jetson-security.md decisions log):
#   - ftpm.conf: blacklist tpm_ftpm_tee so udev's coldplug cannot autoload it
#     before tee-supplicant; tee-ftpm-modprobe still loads it by name afterwards.
#     Without this the fTPM runs from RAM and sealed keys die at reboot.
#   - 10-early.conf: start tee-supplicant + tee-ftpm-modprobe before local-fs
#     instead of after basic.target, so /dev/tpmrm0 exists early enough for
#     data.mount's unlock chain (else deadlock: local-fs <-> basic.target).
#   - 20-tpm-wait.conf: make the unlock (systemd-cryptsetup@data) and the
#     first-boot enroll (data-enroll) wait for dev-tpmrm0.device.
# Gate off (the default): nothing is installed, stock optee-client behavior.
SRC_URI += "${@' file://ftpm.conf file://10-early.conf file://20-tpm-wait.conf' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"

do_install:append() {
    if [ "${WENDYOS_ENABLE_TPM}" = "1" ]; then
        install -D -m 0644 ${UNPACKDIR}/ftpm.conf ${D}${sysconfdir}/modprobe.d/ftpm.conf

        for u in tee-supplicant.service tee-ftpm-modprobe.service; do
            install -D -m 0644 ${UNPACKDIR}/10-early.conf \
                ${D}${systemd_system_unitdir}/$u.d/10-early.conf
        done

        for u in systemd-cryptsetup@data.service data-enroll.service; do
            install -D -m 0644 ${UNPACKDIR}/20-tpm-wait.conf \
                ${D}${systemd_system_unitdir}/$u.d/20-tpm-wait.conf
        done
    fi
}

FILES:${PN} += " \
    ${sysconfdir}/modprobe.d/ftpm.conf \
    ${systemd_system_unitdir}/tee-supplicant.service.d \
    ${systemd_system_unitdir}/tee-ftpm-modprobe.service.d \
    ${systemd_system_unitdir}/systemd-cryptsetup@data.service.d \
    ${systemd_system_unitdir}/data-enroll.service.d \
    "

