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
#
# qcom-refgen-regulator is deliberately absent, though the hardware wants it: it
# lets 8906000.phy probe, which brings up a400000.usb as a SECOND UDC, and
# gadget-setup.sh picks its controller with `ls /sys/class/udc | head -n1`. That
# selects a400000.usb, the gadget binds to a port with no cable, and usb0 goes down
# -- taking away the board's only host link. Install it once that script selects
# its UDC explicitly rather than by sort order.
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
    "

# The PMIC RTC is read-only and volatile, so timesyncd's saved timestamp on /data
# is the only thing keeping the clock sane across a reboot or an OTA swap.
RDEPENDS:${PN} += " systemd-mount-timesync"

# Qualcomm AI stack, gated on WENDYOS_QCOM_NPU (see the machine conf for why it is
# off by default). The kernel half already ships: fastrpc is loaded, the cDSP boots
# from linux-firmware, and qairt-sdk-hexagon-v75 supplies the DSP-side skels. What
# these add is the host-side runtime plus the board's DSP blobs.
#
# The -config package is what makes offload work: it drops a conf.d yaml keyed on
# the DT model ("Qualcomm Technologies, Inc. Monaco EVK") that tells fastrpc's
# config parser where the skels live, and the -evk-{adsp,cdsp,gdsp} packages are
# symlinks creating exactly that path. Without it DSP_LIBRARY_PATH is never set and
# every offload call fails.
WENDYOS_QCOM_NPU_INSTALL = " \
    qairt-sdk \
    hexagon-dsp-binaries-qualcomm-iq8275-evk-config \
    hexagon-dsp-binaries-qcom-iq8275-evk-adsp \
    hexagon-dsp-binaries-qcom-iq8275-evk-cdsp \
    hexagon-dsp-binaries-qcom-iq8275-evk-gdsp \
    "
RDEPENDS:${PN} += "${@d.getVar('WENDYOS_QCOM_NPU_INSTALL') if d.getVar('WENDYOS_QCOM_NPU') == '1' else ''}"

COMPATIBLE_MACHINE = "iq-8275-evk-wendyos"
