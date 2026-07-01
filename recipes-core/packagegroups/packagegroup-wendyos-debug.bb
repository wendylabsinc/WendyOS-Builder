
PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

# ss(8) for socket/port inspection
# getent(1) for NSS/DNS lookups
SUMMARY:${PN} = "Debugging package group"
RDEPENDS:${PN} = " \
    ${@oe.utils.ifelse( \
        d.getVar('WENDYOS_DEBUG') == '1', \
        ' \
            mmc-utils \
            fio \
            memtester \
            gperftools \
            bash \
            rt-tests \
            nfs-utils \
            procps \
            sysstat \
            ldd \
            bc  \
            iproute2-ss \
        ', \
        '' \
        )} \
    "

# Tegra-specific debug tools (Jetson hardware only)
RDEPENDS:${PN}:append:tegra = " \
    ${@oe.utils.ifelse( \
        d.getVar('WENDYOS_DEBUG') == '1', \
        'python3-jetson-stats', \
        '' \
        )} \
    "

# OP-TEE test / token-inspection tooling (Jetson hardware only):
# optee-test = xtest (TA conformance suite, incl. PKCS#11) + its regression TAs.
# opensc = pkcs11-tool, which drives the PKCS#11 token via the standard
# Cryptoki module /usr/lib/libckteec.so.0.
RDEPENDS:${PN}:append:tegra = " \
    ${@oe.utils.ifelse( \
        d.getVar('WENDYOS_DEBUG') == '1', \
        'optee-test opensc', \
        '' \
        )} \
    "
