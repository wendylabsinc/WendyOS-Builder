# Shared build for a WendyOS out-of-tree driver module.
#
# A per-driver recipe inherits this and sets only a descriptor: SUMMARY, LICENSE +
# LIC_FILES_CHKSUM, and SRC_URI (the vendor source — git+SRCREV, or local files).
# The module is compiled against the pinned base kernel (module.bbclass wires
# KERNEL_SRC=STAGING_KERNEL_DIR), so the .ko gets the correct vermagic/ABI for that
# exact OS version. A per-driver sysext image (inherit wendyos-sysext-image) then
# packages the resulting kernel-module-* package into a .raw the agent merges at
# runtime.
#
# Goal: adding a driver = this thin descriptor + a short image recipe, with no
# bespoke build logic. A driver whose source won't build against our kernel adds a
# patch to SRC_URI — the only exception to "pure descriptor". Rebuilding per kernel
# bump is a CI job, not per-recipe work.
#
# This class is the single place to add shared cross-driver build conventions as
# more drivers land.

inherit module
