# Qualcomm-specific distro configuration, shared by every qcom board.

# The Hexagon DSP userspace comes unmodified from meta-qcom's hexagon-dsp-binaries.
# The signed DSP firmware only runs userspace builds it authorises. meta-qcom pins
# each DSP package to the matching linux-firmware version. With WENDYOS_QCOM_NPU on,
# packagegroup-wendyos-qcom makes those packages hard dependencies, so a mismatch
# fails the image build. We used to retarget the build (335bcea) while oe-core's
# linux-firmware lagged behind. That was removed when both reached 20260916. If they
# drift apart again, align the layers or bring the retarget back.
