# RPi local config for the blacksail-tree experiment.
#
# Go 1.26 is native on blacksail (no meta-lts-mixins-go), so the
# rpi5-sd-blacksail board's repos.overrides omits that REPOS_EXTRA clone.
WENDYOS_PERSIST_JOURNAL_LOGS = "0"

# U-Boot: blacksail-native oe-core U-Boot 2026.04, no version pin needed.
#
# It boots the Pi 5 fine (confirmed via the dedicated debug connector). The
# earlier "2026.04 won't boot" was a console-routing red herring: on the newer
# 6.12 DTB the effective console is on serial10 (the 3-pin debug connector), not
# serial0/GPIO14-15 where we were watching. We briefly pinned 2025.04 from
# meta-lts-mixins, but that backport is unnecessary and has been dropped (layer
# + bridge removed from bblayers/rpi-blacksail.inc), so oe-core 2026.04 is now
# the only U-Boot provider. See the memory note project_rpi5_blacksail_uboot_silent.

# ffmpeg provider: pin to the blacksail-native oe-core `ffmpeg`, NOT meta-
# raspberrypi's `rpidistro-ffmpeg` fork. Both PROVIDE ffmpeg/libav/libpostproc
# (and produce identically-named libav* packages), so without a pin bitbake
# warns "Multiple providers are available for ffmpeg" and picks one
# non-deterministically; if it ever builds both they collide in the shared
# pkgdata area (do_packagedata "files already exist").
#
# scarthgap prefers rpidistro-ffmpeg (for Pi hardware codecs) via meta-
# raspberrypi's rpi-default-providers.inc, but on blacksail rpidistro-ffmpeg is
# only a wrynose-compat fork bridged in -- fragile on this newer oe-core -- and
# the RPi5 camera path here is libcamera/GStreamer, not ffmpeg-codec-bound. So
# we use the native ffmpeg, which also avoids pulling the fork into the build.
PREFERRED_PROVIDER_ffmpeg ?= "ffmpeg"
PREFERRED_PROVIDER_libav ?= "ffmpeg"
PREFERRED_PROVIDER_libpostproc ?= "ffmpeg"

