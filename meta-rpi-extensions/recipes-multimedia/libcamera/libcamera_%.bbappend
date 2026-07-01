# WendyOS: build libcamera for the Raspberry Pi 5 (BCM2712 + RP1 CFE) camera
# path. On a Pi 5 the capture path goes through the PiSP ISP, handled by
# libcamera's rpi/pisp pipeline -- without it `cam --list` enumerates zero
# cameras even after the sensor probes. And the agent streams through
# `libcamerasrc`, libcamera's GStreamer source element, so we also need the
# gstreamer plugin (packaged libcamera-gst, see packagegroup-wendyos-rpi).
#
# What it takes to get rpi/pisp differs by oe-core tree, so the PiSP wiring
# below is gated on LAYERSERIES_CORENAMES (same discriminator the libpisp recipe
# in this layer uses):
#
#   blacksail: meta-oe ships libcamera 0.7.1, whose recipe already folds
#     rpi/pisp,rpi/vc4 into ARM_PIPELINES via the `raspberrypi` PACKAGECONFIG,
#     and blacksail's meta-raspberrypi libcamera bbappend enables that
#     PACKAGECONFIG (+ -Dipas=rpi/vc4,rpi/pisp) and ships libpisp 1.3.0 itself.
#     PiSP is handled upstream -- we add ONLY the gstreamer element. We must NOT
#     pin the old RPi 0.4.0 fork here: in 0.4.0 the `v4l2` meson option is a
#     boolean while the 0.7.1 recipe passes -Dv4l2=enabled (a feature value), so
#     meson aborts with 'Option "v4l2" value enabled is not boolean'.
#
#   scarthgap: meta-oe ships libcamera 0.4.0 and its meta-raspberrypi (at the
#     SRCREV WendyOS pins) has neither the rpi/pisp pipeline nor libpisp. Plain
#     0.4.0 upstream lacks rpi/pisp entirely (meson: "Options 'rpi/pisp' are not
#     in allowed choices"), so we build from the RPi fork at v0.4.0+rpt20250213
#     (upstream 0.4.0 + the downstream src/libcamera/pipeline/rpi/pisp patches),
#     wire -Dpipelines/-Dipas ourselves, and depend on the libpisp port carried
#     in this layer (recipes-multimedia/libpisp). LIC_FILES_CHKSUM is unchanged
#     (the fork's LICENSES/*.txt are byte-identical). Pin by SRCREV with
#     nobranch=1: the +rpt tag is not on the fork's main tip and the scarthgap
#     fetcher rejects a url carrying both tag= and SRCREV (see libpisp_1.3.0.bb).

# Build the GStreamer element (`libcamerasrc`); both trees need it. Accumulates
# with meta-raspberrypi's own PACKAGECONFIG:append:rpi = " raspberrypi".
PACKAGECONFIG:append:rpi = " gst"

# scarthgap-only PiSP pipelines/IPAs, injected through a variable so this
# EXTRA_OEMESON:append:rpi keeps landing AFTER meta-raspberrypi's vc4-only
# options on the meson command line (meson honours the last occurrence of a
# repeated option, so vc4,pisp wins). Empty on blacksail.
LIBCAMERA_RPI_PISP_OEMESON ?= ""
EXTRA_OEMESON:append:rpi = "${LIBCAMERA_RPI_PISP_OEMESON}"

python () {
    if 'scarthgap' not in (d.getVar('LAYERSERIES_CORENAMES') or '').split():
        return
    # Repoint to the RPi 0.4.0 fork (adds src/libcamera/pipeline/rpi/pisp) and
    # wire the PiSP pipeline + IPA + libpisp dependency ourselves.
    d.setVar('SRC_URI', 'git://github.com/raspberrypi/libcamera.git;protocol=https;nobranch=1')
    d.setVar('SRCREV', '29156679717bec7cc4784aeba3548807f2c27fca')
    d.setVar('LIBCAMERA_RPI_PISP_OEMESON', ' -Dpipelines=rpi/vc4,rpi/pisp -Dipas=rpi/vc4,rpi/pisp')
    d.appendVar('DEPENDS', ' libpisp')
}

