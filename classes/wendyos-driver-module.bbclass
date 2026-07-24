# Shared build for a WendyOS out-of-tree driver module. A per-driver recipe
# inherits this and sets only a descriptor (SUMMARY, LICENSE, SRC_URI — plus a patch
# if the source won't build against our kernel). module.bbclass compiles it against
# the pinned base kernel, so the .ko gets the right vermagic/ABI; a sysext image
# (inherit wendyos-sysext-image) then packs the kernel-module-* package into the
# .raw the agent merges at runtime.

inherit module
