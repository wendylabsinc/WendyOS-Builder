# WendyOS: build libcamera with the Raspberry Pi PiSP pipeline and the
# GStreamer source element, for the Raspberry Pi 5 (BCM2712 + RP1 CFE) camera
# path. On a Pi 5 the capture path goes through the PiSP ISP, handled by
# libcamera's rpi/pisp pipeline -- without it `cam --list` enumerates zero
# cameras even after the sensor probes. And without the gstreamer element the
# `libcamerasrc` the agent streams through does not exist, leaving it to fall
# back to a non-working v4l2src on raw Bayer.
#
# Source repoint -- the crux. The libcamera *recipe* WendyOS builds comes from
# meta-openembedded (meta-multimedia/recipes-multimedia/libcamera/
# libcamera_0.4.0.bb), which fetches UPSTREAM libcamera (git.libcamera.org @
# 35ed4b91 == the plain v0.4.0 release). Upstream's meson `pipelines` choices
# are imx8-isi/ipu3/mali-c55/rkisp1/rpi/vc4/simple/uvcvideo/vimc/virtual -- it
# ships rpi/vc4 but NOT rpi/pisp; the PiSP pipeline handler lives only in the
# Raspberry Pi downstream fork. So just adding -Dpipelines=...,rpi/pisp (below)
# to the upstream source makes meson abort: "Options 'rpi/pisp' are not in
# allowed choices". meta-raspberrypi only wires PiSP up on master/whinlatter,
# not the scarthgap branch we pin.
#
# Fix: build from the RPi fork at v0.4.0+rpt20250213 -- upstream 0.4.0 plus the
# downstream patches that add src/libcamera/pipeline/rpi/pisp. Same 0.4.0 API,
# so it stays compatible with rpicam-apps 1.4.2 and the libpisp 1.3.0 carried
# alongside (recipes-multimedia/libpisp). LIC_FILES_CHKSUM is unchanged (the
# fork's LICENSES/*.txt are byte-identical). We reassign SRC_URI wholesale,
# which also drops meta-oe's clang-only unlock() -Wunused-result patch -- the
# fork builds with GCC for Raspberry Pi OS and does not need it. Pin by SRCREV
# with nobranch=1: the +rpt tag is not on the fork's main tip, and the
# scarthgap git fetcher rejects a url carrying both tag= and SRCREV (see the
# matching note in libpisp_1.3.0.bb).
SRC_URI = "git://github.com/raspberrypi/libcamera.git;protocol=https;nobranch=1"
SRCREV = "29156679717bec7cc4784aeba3548807f2c27fca"

# Enable the rpi/pisp pipeline (and its IPA) alongside rpi/vc4. Append to
# EXTRA_OEMESON, not PACKAGECONFIG[raspberrypi], so our values land AFTER
# meta-raspberrypi's vc4-only -Dpipelines/-Dipas on the meson command line;
# meson honours the last occurrence of a repeated option, so vc4,pisp wins
# regardless of bbappend parse order. Mirrors the upstream master bbappend's
# EXTRA_OEMESON:append:rpi approach.
EXTRA_OEMESON:append:rpi = " -Dpipelines=rpi/vc4,rpi/pisp -Dipas=rpi/vc4,rpi/pisp"

# Build the GStreamer element: provides `libcamerasrc`, packaged as
# libcamera-gst (see packagegroup-wendyos-rpi). Accumulates with
# meta-raspberrypi's own `PACKAGECONFIG:append:rpi = " raspberrypi"`.
PACKAGECONFIG:append:rpi = " gst"

# The rpi/pisp pipeline handler links against libpisp, ported into this layer
# (recipes-multimedia/libpisp) because the pinned meta-raspberrypi lacks it.
DEPENDS:append:rpi = " libpisp"
