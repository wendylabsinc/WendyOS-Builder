# WendyOS: enable the PiSP pipeline and the GStreamer source element on top of
# meta-raspberrypi's vc4-only libcamera default.
#
# The meta-raspberrypi revision WendyOS pins (scarthgap branch) ships a
# libcamera bbappend that builds ONLY the rpi/vc4 pipeline (Raspberry Pi 0-4)
# and leaves the gstreamer element disabled. On a Raspberry Pi 5 (BCM2712 +
# RP1 CFE) the camera capture path goes through the PiSP ISP, handled by
# libcamera's rpi/pisp pipeline -- so without it `cam --list` enumerates zero
# cameras even after the sensor probes. And without the gstreamer element the
# `libcamerasrc` the agent streams through does not exist, leaving it to fall
# back to a non-working v4l2src on raw Bayer. Upstream meta-raspberrypi added
# PiSP support (libpisp + rpi/pisp) only on master/whinlatter, not the
# scarthgap branch we pin, so we wire it up here.
#
# Append to EXTRA_OEMESON (not a redefinition of PACKAGECONFIG[raspberrypi])
# so our values land AFTER meta-raspberrypi's vc4-only -Dpipelines/-Dipas on
# the meson command line; meson honours the last occurrence of a repeated
# option, so vc4,pisp wins regardless of bbappend parse order. This mirrors the
# upstream master bbappend's EXTRA_OEMESON:append:rpi approach.
EXTRA_OEMESON:append:rpi = " -Dpipelines=rpi/vc4,rpi/pisp -Dipas=rpi/vc4,rpi/pisp"

# Build the GStreamer element: provides `libcamerasrc`, packaged as
# libcamera-gst (see packagegroup-wendyos-rpi). Accumulates with
# meta-raspberrypi's own `PACKAGECONFIG:append:rpi = " raspberrypi"`.
PACKAGECONFIG:append:rpi = " gst"

# The rpi/pisp pipeline handler links against libpisp, ported into this layer
# (recipes-multimedia/libpisp) because the pinned meta-raspberrypi lacks it.
DEPENDS:append:rpi = " libpisp"
