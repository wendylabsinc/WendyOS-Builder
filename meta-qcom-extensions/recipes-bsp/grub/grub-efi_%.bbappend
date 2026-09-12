# Modules the A/B grub.cfg needs that stock GRUB_BUILDIN omits. grub-mkimage bakes
# the module set into bootaa64.efi and the ESP carries no module directory, so a
# command that is not built in is simply absent -- `echo` was missing on the first
# hardware test and every message vanished silently.
#   regexp - derive the boot disk from $root; an OTA clobbers a slot's fs LABEL, so
#            the boot chain keys off GPT partition numbers instead.
#   reboot - a slot whose kernel will not load must reboot so the bootcount logic
#            falls back, rather than hang at the menu on a headless board.
#   sleep  - paces that reboot loop when BOTH slots are unbootable.
#   fdt    - provides `devicetree`; without our DTB the kernel inherits UEFI's
#            vendor one, which lacks the UFS bindings this kernel needs.
GRUB_BUILDIN:append = " regexp reboot sleep echo fdt"
