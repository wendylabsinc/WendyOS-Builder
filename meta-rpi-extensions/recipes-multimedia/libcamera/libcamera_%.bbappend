# WendyOS: build libcamera for the Raspberry Pi 5 (BCM2712 + RP1 CFE) camera
# path. On a Pi 5 the capture path goes through the PiSP ISP, handled by
# libcamera's rpi/pisp pipeline -- without it `cam --list` enumerates zero
# cameras even after the sensor probes. And the agent streams through
# `libcamerasrc`, libcamera's GStreamer source element, so we also need the
# gstreamer plugin (packaged libcamera-gst, see packagegroup-wendyos-rpi).
#
# PiSP itself needs no wiring here: meta-oe ships libcamera 0.7.2, whose recipe
# already folds rpi/pisp,rpi/vc4 into ARM_PIPELINES via the `raspberrypi`
# PACKAGECONFIG, and meta-raspberrypi's libcamera bbappend enables that
# PACKAGECONFIG (+ -Dipas=rpi/vc4,rpi/pisp) and ships libpisp 1.3.0 itself. We
# must NOT pin the old RPi 0.4.0 fork here: in 0.4.0 the `v4l2` meson option is
# a boolean while the 0.7.x recipe passes -Dv4l2=enabled (a feature value), so
# meson aborts with 'Option "v4l2" value enabled is not boolean'.

# Build the GStreamer element (`libcamerasrc`). Accumulates with
# meta-raspberrypi's own PACKAGECONFIG:append:rpi = " raspberrypi".
PACKAGECONFIG:append:rpi = " gst"
