FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# Two agatti.dtsi defaults that do not hold for this board and kernel: a
# reusable ADSP remote heap, which lets Linux use memory the DSP owns, and the
# MPM linked as the cluster domain's parent, which leaves root never mounted.
# The MPM workaround will be dropped first, so it applies last.
SRC_URI:append:arduino-uno-q-wendyos = " \
    file://0001-arm64-dts-qcom-imola-keep-the-ADSP-remote-heap-out-of-the-page-allocator.patch \
    file://0002-arm64-dts-qcom-imola-attach-MPM-to-the-cluster-power-domain.patch \
    "
