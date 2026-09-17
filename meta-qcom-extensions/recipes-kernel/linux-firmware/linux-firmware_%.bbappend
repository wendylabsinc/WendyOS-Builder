# Drop a meta-qcom backport patch that cannot apply against the pinned oe-core.
#
# meta-qcom's own linux-firmware bbappend adds
# 0001-qcom-sa8775p-update-signature-on-cdsp1-firmware.patch, authored against
# linux-firmware 20260810. SRCREV_OECORE pins a tree that still ships 20260622,
# whose qcom/sa8775p/cdsp1.mbn is a third, unrelated blob. A git *delta* binary
# patch cannot apply without its exact preimage, and GNU patch is GitApplyTree's
# last fallback -- so the real cause surfaces as the misleading
# "git binary diffs are not supported".
#
# Safe, not merely expedient: the pinned DSP userspace is authorised by the
# UNPATCHED cdsp1.mbn this linux-firmware ships, and lemans really does load
# qcom/sa8775p/cdsp1.mbn. Re-check with dsp-binaries' scripts/checkfw.py before
# moving either version.
#
# Unconditional because this layer is only in BBLAYERS for the Dragonwing boards
# (conf/template/include/bblayers/qcom.inc). Delete this file once SRCREV_OECORE
# moves past linux-firmware 20260810.
SRC_URI:remove = "file://0001-qcom-sa8775p-update-signature-on-cdsp1-firmware.patch"
