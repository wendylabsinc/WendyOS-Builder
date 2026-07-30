# Test driver add-on: packages the wendyos_hello self-test module as a .raw so
# the on-device apply path (merge -> overlay -> depmod -> modprobe) can be
# validated on real hardware without accelerator hardware.
SUMMARY = "Test driver add-on (wendyos_hello) as a systemd-sysext image"
LICENSE = "MIT"

inherit wendyos-sysext-image

# Stable add-on id → on-device file is wendyos-hello.raw (extension-release.wendyos-hello).
WENDYOS_SYSEXT_NAME = "wendyos-hello"

# The driver declares its own module — baked into the image, so `wendy device drivers
# install wendyos-hello` needs no --module flag (a real driver like Coral would set
# "gasket apex" here).
WENDYOS_SYSEXT_MODULES = "wendyos_hello"

# The recipe meta-package pulls in its split kernel-module-* .ko via RDEPENDS.
IMAGE_INSTALL = "wendyos-driver-hello"
