# Retarget the DSP userspace to the build our firmware authorises, and correct the
# version pin that expresses that pairing. See WENDYOS_QCOM_DSP_BUILD in qcom-distro.inc.

# Edited in place rather than by overriding do_install, so upstream's install target
# keeps working. The sed is idempotent.
do_install:prepend() {
    for soc in ${WENDYOS_QCOM_DSP_SOCS}; do
        sed -i -E "/^Install:[[:space:]]+$soc\//s/DSP\.AT\.[0-9.]+-[0-9.]+-LEMANS-[0-9]+/${WENDYOS_QCOM_DSP_BUILD}/" \
            "${S}/config.txt"

        # A sed that matched nothing leaves a selection the firmware refuses at
        # runtime, with a green build.
        if ! grep -q "^Install:[[:space:]]\+$soc/.*${WENDYOS_QCOM_DSP_BUILD}" "${S}/config.txt"; then
            bbfatal "no Install: line for $soc names ${WENDYOS_QCOM_DSP_BUILD}; upstream's \
config.txt format changed or it no longer ships that build"
        fi
    done
}

# Upstream derives these pins from its own PV, which the shipped firmware does not
# satisfy. Rewritten, not dropped: the pin is what makes a future skew a build failure.
#
# Only where the firmware named belongs to a retargeted SoC; elsewhere the pairing was
# never checked. Matched on the firmware package, since the package name does not
# identify the SoC.
python () {
    import re
    fwpv = d.getVar('WENDYOS_QCOM_DSP_FW_PV')
    if not fwpv:
        bb.fatal("WENDYOS_QCOM_DSP_FW_PV is unset; it must name the linux-firmware "
                 "version oe-core ships")
    socs = (d.getVar('WENDYOS_QCOM_DSP_SOCS') or '').split()
    if not socs:
        bb.fatal("WENDYOS_QCOM_DSP_SOCS is unset; nothing would be retargeted")
    pin = re.compile(r'(linux-firmware-qcom-(?:%s)-[a-z]+ \(= 1:)%s\b'
                     % ('|'.join(map(re.escape, socs)), re.escape(d.getVar('PV'))))
    for pkg in (d.getVar('PACKAGES') or '').split():
        var = 'RDEPENDS:' + pkg
        cur = d.getVar(var)
        if cur:
            new = pin.sub(r'\g<1>' + fwpv, cur)
            if new != cur:
                d.setVar(var, new)
}
