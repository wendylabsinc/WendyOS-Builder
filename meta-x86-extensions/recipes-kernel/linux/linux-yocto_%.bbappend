FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:x86-wendyos = " \
    file://x86-nuc-drivers.cfg \
    "

# Disable kernel IBT only when the NVIDIA dGPU stack is baked in — the
# out-of-tree module's RM core lacks ENDBR landing pads and faults under IBT.
# See files/nvidia-ibt.cfg.
SRC_URI:append:x86-wendyos = "${@' file://nvidia-ibt.cfg' if d.getVar('WENDYOS_NVIDIA_DGPU') == '1' else ''}"
