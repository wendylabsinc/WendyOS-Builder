# The A/B grub.cfg (files/wic/grubAB.cfg) resolves the rootfs slot by PARTITION
# NUMBER on the boot disk, deriving the disk from $root with `regexp`. Stock
# GRUB_BUILDIN does not ship the regexp module, so add it.
#
# Why partition number and not `search --label`: an OTA raw-writes the payload into
# the target slot, which CLOBBERS that slot's ext4 filesystem label (the payload
# carries its own single label). So a slot's fs label is not a durable identity. The
# GPT partition NUMBER and PARTLABEL survive (the partition table is never rewritten
# by an OTA), so the boot chain keys off those instead.
GRUB_BUILDIN:append = " regexp"
