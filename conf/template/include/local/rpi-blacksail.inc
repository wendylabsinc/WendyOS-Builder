# RPi local config for the blacksail tree.

# Volatile journal logs in tmpfs (no /data partition).
WENDYOS_PERSIST_JOURNAL_LOGS = "0"

# U-Boot: oe-core's stock U-Boot v2026.07, no version pin. It is the only U-Boot
# provider. The Pi 5 boot fixes are in meta-rpi-extensions' u-boot bbappend.
#
# When checking that a Pi 5 boots, watch serial10 (the 3-pin debug connector).
# On the newer DTB the console is there, not on serial0/GPIO14-15.

# ffmpeg provider: pin to the blacksail-native oe-core `ffmpeg`, NOT meta-
# raspberrypi's `rpidistro-ffmpeg` fork. Both PROVIDE ffmpeg/libav/libpostproc
# (and produce identically-named libav* packages), so without a pin bitbake
# warns "Multiple providers are available for ffmpeg" and picks one
# non-deterministically; if it ever builds both they collide in the shared
# pkgdata area (do_packagedata "files already exist").
#
# The fork exists for Pi hardware codecs, but the RPi5 camera path here is
# libcamera/GStreamer, not ffmpeg-codec-bound. So we use the native ffmpeg,
# which also avoids pulling the fork into the build.
PREFERRED_PROVIDER_ffmpeg ?= "ffmpeg"
PREFERRED_PROVIDER_libav ?= "ffmpeg"
PREFERRED_PROVIDER_libpostproc ?= "ffmpeg"
