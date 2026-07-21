# Test driver add-on: packages the wendyos_hello self-test module as a .raw so the
# full on-device apply path (merge -> overlay -> depmod -> modprobe) can be
# validated on a real RPi5 without accelerator hardware. Build + apply:
#   bitbake wendyos-driver-hello-image
#   copy .../wendyos-driver-hello-image-*.sysext.squashfs-xz to the device
#     /data/extensions/enabled/wendyos-hello.raw
#   echo wendyos_hello > /data/extensions/modules-load.d/hello.conf
#   reboot  (or run /usr/sbin/wendyos-sysext-apply.sh)  -> lsmod | grep wendyos_hello
SUMMARY = "Test driver add-on (wendyos_hello) as a systemd-sysext image"
LICENSE = "MIT"

inherit wendyos-sysext-image

# Stable add-on id → on-device file is wendyos-hello.raw (extension-release.wendyos-hello).
WENDYOS_SYSEXT_NAME = "wendyos-hello"

# The recipe meta-package pulls in its split kernel-module-* .ko via RDEPENDS.
IMAGE_INSTALL = "wendyos-driver-hello"
