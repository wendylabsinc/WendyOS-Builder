SUMMARY = "WendyOS Dragonwing-specific packages"
LICENSE = "MIT"
PACKAGE_ARCH = "${MACHINE_ARCH}"
inherit packagegroup

# Drivers meta-qcom's kernel builds but installs nothing of. Each absence is
# silent -- the interface simply never appears -- hence RDEPENDS, not RRECOMMENDS:
# a kernel bump that stops emitting one must break the build rather than ship a
# board with no networking. Found by sweeping for devices that have a modalias but
# no driver bound; worth repeating after a kernel uprev.
#
#  pwrseq-pcie-m2      powers the M.2 Key-E slot (/connector-3). Without it
#                      pci@1c00000 waits on its pwrseq provider forever, PCIe
#                      domain 0000 never enumerates and there is no wlan0.
#  at24                ethernet@23040000 takes its MAC from the I2C EEPROM at 0x50
#                      as an nvmem supplier; without it stmmac never leaves
#                      deferred probe and eth0 is absent entirely.
#  qca808x, qcom-phy-lib  the QCA8081 2.5G PHY (id 0x004dd101). Without them the
#                      generic PHY binds and rejects the DT's 2500base-x mode.
#  snd-soc-*           the codecs each board's sound card expects; the machine
#                      driver alone reports "codec dai not found" and yields no
#                      /dev/snd.
#  tpm-tis-*           both boards really do carry a TPM 2.0 on SPI. Installing
#                      the driver does not enable /data encryption --
#                      WENDYOS_DATA_ENCRYPTED stays 0 -- it just stops the
#                      hardware being invisible.
#  uvcvideo            USB webcams on whichever port the board offers in host
#                      role. The rest of the V4L2 stack already ships for the
#                      on-SoC camera path.
RDEPENDS:${PN} = " \
    kernel-module-pwrseq-pcie-m2 \
    kernel-module-at24 \
    kernel-module-qca808x \
    kernel-module-qcom-phy-lib \
    kernel-module-snd-soc-max98357a \
    kernel-module-snd-soc-dmic \
    kernel-module-tpm-tis-core \
    kernel-module-tpm-tis-spi \
    kernel-module-uvcvideo \
    "

# The Wi-Fi stack for the WCN6855 in the M.2 slot. meta-qcom supplies all three
# through RRECOMMENDS, which bitbake drops in silence; without regulatory.db
# cfg80211 also falls back to the world domain and 5 GHz goes passive-only.
RDEPENDS:${PN} += " \
    kernel-module-ath11k-pci \
    linux-firmware-ath11k-wcn6855 \
    wireless-regdb-static \
    "

# Hardware only the 8275 carries.
#
#  lontium-lt8713sx    the DP bridge on i2c. Without it the displayport
#                      controller defers, msm never binds, there is no DRM card
#                      and the GPU never initialises. lemans drives its panels
#                      from native DP and has no such bridge.
#  pinctrl-*-lpass-lpi the LPI pins monaco's sound card routes over; lemans
#                      routes the same two codecs over plain tlmm.
RDEPENDS:${PN}:append:iq-8275-evk = " \
    kernel-module-lontium-lt8713sx \
    kernel-module-pinctrl-lpass-lpi \
    kernel-module-pinctrl-sm8450-lpass-lpi \
    "

#  hd3ss3220           the two Type-C port controllers on i2c. Each gates its
#                      connector's VBUS, so without it a device on either
#                      Type-C socket never gets power. The one at 0x67 also owns
#                      the role switch of the controller WENDYOS_USB_UDC names,
#                      so CC detection can take the gadget port to host role.
RDEPENDS:${PN}:append:iq-9075-evk = " \
    kernel-module-hd3ss3220 \
    "

# The PMIC RTC is read-only and volatile, so timesyncd's saved timestamp on /data
# is the only thing keeping the clock sane across a reboot or an OTA swap.
RDEPENDS:${PN} += " systemd-mount-timesync"

# Qualcomm AI stack for the on-SoC Hexagon NPU, gated on WENDYOS_QCOM_NPU. fastrpc and
# the DSP firmware already ship with the kernel.
#
# RDEPENDS, not RRECOMMENDS: meta-qcom reaches these through
# MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS, where an unsatisfiable entry is dropped silently.
#
# The -evk-* packages are symlinks onto the -ride-* payload; -evk-config supplies the
# DT-model to DSP_LIBRARY_PATH mapping that offload needs.
#
# One -cdsp/-gdsp package per board regardless of DSP count: dsp-binaries globs
# cdsp*/gdsp*, so a board with two of each needs no extra entry.
WENDYOS_QCOM_NPU_INSTALL = " \
    hexagon-dsp-binaries-qualcomm-${WENDYOS_QCOM_NPU_BOARD}-config \
    hexagon-dsp-binaries-qcom-${WENDYOS_QCOM_NPU_BOARD}-adsp \
    hexagon-dsp-binaries-qcom-${WENDYOS_QCOM_NPU_BOARD}-cdsp \
    hexagon-dsp-binaries-qcom-${WENDYOS_QCOM_NPU_BOARD}-gdsp \
    qairt-sdk \
    qairt-sdk-hexagon-${WENDYOS_QCOM_NPU_DSP_ARCH} \
    fastrpc-tests \
    "
RDEPENDS:${PN} += "${@d.getVar('WENDYOS_QCOM_NPU_INSTALL') if d.getVar('WENDYOS_QCOM_NPU') == '1' else ''}"

# Both mistakes are otherwise silent: an unset variable ships a package name
# containing ${...}, and an unretargeted SoC builds green and refuses offload.
python () {
    if d.getVar('WENDYOS_QCOM_NPU') != '1':
        return
    for var in ('WENDYOS_QCOM_NPU_BOARD', 'WENDYOS_QCOM_NPU_DSP_ARCH',
                'WENDYOS_QCOM_NPU_SOC'):
        if not d.getVar(var):
            bb.fatal("%s is unset; the machine conf must name it" % var)
    soc = d.getVar('WENDYOS_QCOM_NPU_SOC')
    if soc not in (d.getVar('WENDYOS_QCOM_DSP_SOCS') or '').split():
        bb.fatal("WENDYOS_QCOM_NPU_SOC '%s' is not in WENDYOS_QCOM_DSP_SOCS; the "
                 "DSP userspace would not be retargeted for it" % soc)
}

COMPATIBLE_MACHINE = "qcom-wendyos"
