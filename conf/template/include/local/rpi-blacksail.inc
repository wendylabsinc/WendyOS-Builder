# RPi local config for the blacksail tree.

# Volatile journal logs in tmpfs (no /data partition).
WENDYOS_PERSIST_JOURNAL_LOGS = "0"

# U-Boot: blacksail-native oe-core U-Boot 2026.04, no version pin needed.
#
# It boots the Pi 5 fine (confirmed via the dedicated debug connector). The
# earlier "2026.04 won't boot" was a console-routing red herring: on the newer
# DTB the effective console is on serial10 (the 3-pin debug connector), not
# serial0/GPIO14-15 where we were watching. oe-core 2026.04 is the only U-Boot
# provider. See the memory note project_rpi5_blacksail_uboot_silent.

# ffmpeg provider: pin to the blacksail-native oe-core `ffmpeg`, NOT meta-
# raspberrypi's `rpidistro-ffmpeg` fork. Both PROVIDE ffmpeg/libav/libpostproc
# (and produce identically-named libav* packages), so without a pin bitbake
# warns "Multiple providers are available for ffmpeg" and picks one
# non-deterministically; if it ever builds both they collide in the shared
# pkgdata area (do_packagedata "files already exist").
#
# The fork exists for Pi hardware codecs, but it ships in a layer that only
# declares wrynose and is bridged in -- fragile on this newer oe-core -- and the
# RPi5 camera path here is libcamera/GStreamer, not ffmpeg-codec-bound. So we use
# the native ffmpeg, which also avoids pulling the fork into the build.
PREFERRED_PROVIDER_ffmpeg ?= "ffmpeg"
PREFERRED_PROVIDER_libav ?= "ffmpeg"
PREFERRED_PROVIDER_libpostproc ?= "ffmpeg"
