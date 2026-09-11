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
#  lontium-lt8713sx    the DP bridge at i2c 0x4f. Without it
#                      displayport-controller@af54000 defers, msm never binds,
#                      there is no DRM card and the GPU never initialises.
#  snd-soc-*, pinctrl-*-lpass-lpi  the codecs qcs8275-sndcard expects and the LPI
#                      pins it routes over; the machine driver alone reports
#                      "codec dai not found" and yields no /dev/snd. The sm8450
#                      pinctrl variant cannot load without its core module.
#  tpm-tis-*           the board really does carry a TPM 2.0 on spi0.0. Installing
#                      the driver does not enable /data encryption --
#                      WENDYOS_DATA_ENCRYPTED stays 0 -- it just stops the
#                      hardware being invisible.
#  uvcvideo            USB webcams on the host port. The rest of the V4L2 stack
#                      already ships for the on-SoC camera path.
RDEPENDS:${PN} = " \
    kernel-module-pwrseq-pcie-m2 \
    kernel-module-at24 \
    kernel-module-qca808x \
    kernel-module-qcom-phy-lib \
    kernel-module-lontium-lt8713sx \
    kernel-module-snd-soc-max98357a \
    kernel-module-snd-soc-dmic \
    kernel-module-pinctrl-lpass-lpi \
    kernel-module-pinctrl-sm8450-lpass-lpi \
    kernel-module-tpm-tis-core \
    kernel-module-tpm-tis-spi \
    kernel-module-uvcvideo \
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
WENDYOS_QCOM_NPU_INSTALL = " \
    hexagon-dsp-binaries-qualcomm-iq8275-evk-config \
    hexagon-dsp-binaries-qcom-iq8275-evk-adsp \
    hexagon-dsp-binaries-qcom-iq8275-evk-cdsp \
    hexagon-dsp-binaries-qcom-iq8275-evk-gdsp \
    qairt-sdk \
    qairt-sdk-hexagon-v75 \
    fastrpc-tests \
    "
RDEPENDS:${PN} += "${@d.getVar('WENDYOS_QCOM_NPU_INSTALL') if d.getVar('WENDYOS_QCOM_NPU') == '1' else ''}"

COMPATIBLE_MACHINE = "iq-8275-evk-wendyos"
