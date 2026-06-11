# wendy-update OTA stack. Required from wendyos.conf when
# WENDYOS_OTA == "wendy". Parallels conf/distro/include/mender.inc.
#
# Pulls in the on-device pieces and the build-side artifact:
#   - wendyos-update:      the OTA client (/usr/bin/wendy-update + the
#                          boot-verify and auto-commit systemd units).
#   - wendyos-data-setup:  first-boot /data format/grow + the data.mount.
#   - image_types_wendy:   defines the "wendy" IMAGE_FSTYPE that produces
#                          the .wendy OTA artifact via `wendy-update pack`.

# Scope to the product image only (:pn-wendyos-image): this inc is
# required at distro scope, so a bare :append would also hit the Tegra
# flashing-helper images (tegra-espimage, the initramfs images), each
# producing a bogus .wendy and pulling the OTA client into the initramfs.
IMAGE_INSTALL:append:pn-wendyos-image = " wendyos-update wendyos-data-setup"

# Build the .wendy OTA artifact alongside the flashable image. :append
# (not +=) so it survives machine overrides that *replace* IMAGE_FSTYPES
# (e.g. Thor's `IMAGE_FSTYPES:tegra = "tegraflash-tar"`), and :pn- so only
# the product image gets it. IMAGE_CLASSES stays global — the class only
# defines the "wendy" type; nothing runs unless "wendy" is in IMAGE_FSTYPES.
IMAGE_CLASSES += "image_types_wendy"
IMAGE_FSTYPES:append:pn-wendyos-image = " wendy"
