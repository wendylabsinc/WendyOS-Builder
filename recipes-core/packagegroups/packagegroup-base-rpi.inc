# Note: the /data-dependent recipes (systemd-mount-containerd, wendyos-etc-binds,
# swapfile-setup, wendyos-user-data-setup) are intentionally NOT removed here.
# They are gated on WENDYOS_MENDER in packagegroup-wendyos-base.bb, and 64-bit RPi
# now sets WENDYOS_MENDER=1 (raspberrypi-common-wendyos.inc, WDY-983), so the /data
# partition exists. In particular, systemd-mount-containerd bind-mounts containerd's
# data-root to /data/containerd; without it containerd writes images/snapshots to
# the small A/B root slot and fills it ("no space left on device"). The earlier
# :remove:rpi block here predated RPi Mender support (when there was no /data) and
# became a regression once it was enabled — the WENDYOS_MENDER gate in
# packagegroup-wendyos-base.bb is the single source of truth for these recipes.

# Add RPi5-specific kernel modules
RDEPENDS:${PN}:append:rpi = " \
    kernel-module-option \
    kernel-module-usb-wwan \
    kernel-module-usbserial \
    "
