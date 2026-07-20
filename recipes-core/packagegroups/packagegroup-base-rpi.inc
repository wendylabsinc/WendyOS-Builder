# Note: the /data-dependent recipes (systemd-mount-containerd, systemd-mount-wendy,
# wendyos-etc-binds, swapfile-setup, wendyos-user-data-setup) are intentionally NOT
# removed here.
# 64-bit RPi provisions a /data partition (raspberrypi-common-wendyos.inc, WDY-983),
# so these recipes are kept. In particular, systemd-mount-containerd bind-mounts
# containerd's data-root to /data/containerd; without it containerd writes
# images/snapshots to the small A/B root slot and fills it ("no space left on
# device"). An earlier :remove:rpi block here predated the RPi /data partition
# (when there was no /data) and became a regression once /data was introduced.

# RPi USB-serial kernel modules. usbserial is now built into the kernel (=y, see
# usb-serial.cfg) so it has no module package and is dropped here. option/usb-wwan
# stay =m and remain hard RDEPENDS so a future kernel change that drops them fails
# the build loudly rather than silently losing 3G-modem serial support.
RDEPENDS:${PN}:append:rpi = " \
    kernel-module-option \
    kernel-module-usb-wwan \
    "
