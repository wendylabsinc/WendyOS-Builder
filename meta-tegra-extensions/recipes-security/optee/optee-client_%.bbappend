FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# fTPM boot sequencing. Two pieces, both needed so the fTPM is persistent AND
# ready early enough for the /data unlock. Both follow
# WENDYOS_ENABLE_TPM, the gate for the fTPM itself, regardless of who consumes
# it:
#   - ftpm.conf: blacklist tpm_ftpm_tee so udev's coldplug cannot autoload it
#     before tee-supplicant; tee-ftpm-modprobe still loads it by name afterwards.
#     Without this the fTPM runs from RAM and sealed keys die at reboot.
#   - 10-early.conf: start tee-supplicant + tee-ftpm-modprobe before local-fs
#     instead of after basic.target. The /data resolver (wendyos-data.service)
#     waits for /dev/tpmrm0 inside its own script, and data.mount, which is part
#     of local-fs.target, waits on the resolver. With the stock ordering the
#     fTPM would only start after local-fs, so that wait could never succeed.
#
# Gate off: nothing is installed, stock optee-client behavior. The FILES entries
# below stay unconditional -- a FILES path that matches nothing is ignored, and no
# QA check fires on it (the empty-dirs test is the converse case).
SRC_URI += "${@' file://ftpm.conf file://10-early.conf' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"

do_install:append() {
    if [ "${WENDYOS_ENABLE_TPM}" = "1" ]; then
        install -D -m 0644 ${UNPACKDIR}/ftpm.conf ${D}${sysconfdir}/modprobe.d/ftpm.conf

        for u in tee-supplicant.service tee-ftpm-modprobe.service; do
            install -D -m 0644 ${UNPACKDIR}/10-early.conf \
                ${D}${systemd_system_unitdir}/$u.d/10-early.conf
        done
    fi
}

FILES:${PN} += " \
    ${sysconfdir}/modprobe.d/ftpm.conf \
    ${systemd_system_unitdir}/tee-supplicant.service.d \
    ${systemd_system_unitdir}/tee-ftpm-modprobe.service.d \
    "
