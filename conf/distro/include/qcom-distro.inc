# Qualcomm-specific distro configuration, shared by every qcom board.

# The Hexagon DSP userspace comes unmodified from meta-qcom's hexagon-dsp-binaries.
# The signed DSP firmware only runs userspace builds it authorises. meta-qcom pins
# each DSP package to the matching linux-firmware version. With WENDYOS_QCOM_NPU on,
# packagegroup-wendyos-qcom makes those packages hard dependencies, so a mismatch
# fails the image build. We used to retarget the build (335bcea) while oe-core's
# linux-firmware lagged behind. That was removed when both reached 20260916. If they
# drift apart again, align the layers or bring the retarget back.

# Host-side USB peripheral drivers, as <kernel symbol>:<package>. A module is only
# installed when named; the kernel bbappend, the image and the test read this list.
WENDYOS_QCOM_USB_PERIPHERAL_MODULES = " \
    CONFIG_USB_ACM:kernel-module-cdc-acm \
    CONFIG_USB_SERIAL_CP210X:kernel-module-cp210x \
    CONFIG_USB_SERIAL_FTDI_SIO:kernel-module-ftdi-sio \
    CONFIG_USB_SERIAL_CH341:kernel-module-ch341 \
    CONFIG_USB_SERIAL_PL2303:kernel-module-pl2303 \
    CONFIG_USB_RTL8152:kernel-module-r8152 \
    CONFIG_SND_USB_AUDIO:kernel-module-snd-usb-audio \
    "
