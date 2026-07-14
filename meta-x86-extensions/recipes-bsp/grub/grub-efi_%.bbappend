# The A/B grub.cfg (files/wic/grubAB.cfg) resolves the rootfs slot by PARTITION
# NUMBER on the boot disk, deriving the disk from $root with `regexp`. Stock
# GRUB_BUILDIN does not ship the regexp module, so add it.
#
# Why partition number and not `search --label`: an OTA raw-writes the payload into
# the target slot, which CLOBBERS that slot's ext4 filesystem label (the payload
# carries its own single label). So a slot's fs label is not a durable identity. The
# GPT partition NUMBER and PARTLABEL survive (the partition table is never rewritten
# by an OTA), so the boot chain keys off those instead.
#
# reboot + sleep: when the selected slot's kernel fails to LOAD (missing/corrupt),
# grubAB.cfg does `if ! linux ...; then sleep N; reboot; fi` so the device reboots
# and the bootcount logic re-runs and falls back to the other slot — mirroring the
# U-Boot boards' `reset` on ext4load failure (verified against GRUB source: a failed
# `linux` returns and otherwise GRUB HANGS at the interactive menu on a headless box;
# `||` is not supported in GRUB script, and reboot/sleep are separate modules not in
# `normal`). sleep paces the (only-if-both-slots-are-bad) reboot loop so it is
# observable/interruptible instead of a tight spin.
GRUB_BUILDIN:append = " regexp reboot sleep"
