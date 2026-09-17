# Ported verbatim from meta-raspberrypi master (commit 0e56e2f, "libpisp:
# Upgrade to 1.3.0 release"), back when the meta-raspberrypi revision WendyOS
# pinned predated upstream PiSP support. The Raspberry Pi 5 camera path
# (BCM2712 + RP1 CFE) requires the PiSP backend, whose libcamera pipeline
# handler links against libpisp, so the recipe was carried here.
#
# The pinned meta-raspberrypi now ships its own libpisp_1.3.0.bb (under
# dynamic-layers/multimedia-layer/recipes-multimedia/libpisp), which this copy
# shadows because meta-rpi-extensions has the higher layer priority. This file
# is therefore a candidate for deletion.
DESCRIPTION = "A helper library to generate run-time configuration for the Raspberry Pi \
ISP (PiSP), consisting of the Frontend and Backend hardware components."
HOMEPAGE = "https://github.com/raspberrypi/libpisp"
LICENSE = "BSD-2-Clause & GPL-2.0-only & GPL-2.0-or-later"
LIC_FILES_CHKSUM = "file://LICENSE;md5=3417a46e992fdf62e5759fba9baef7a7 \
                    file://LICENSES/GPL-2.0-only.txt;md5=b234ee4d69f5fce4486a80fdaf4a4263 \
                    file://LICENSES/GPL-2.0-or-later.txt;md5=fed54355545ffd980b814dab4a3b312c"

# Pin by SRCREV only. Upstream tags v1.3.0 at exactly this commit; naming only
# the SRCREV avoids the fetcher having to cross-check tag= against it.
SRC_URI = "git://github.com/raspberrypi/libpisp.git;protocol=https;branch=main"
SRCREV = "9ba67e6680f03f31f2b1741a53e8fd549be82cbe"

# S is deliberately left unset: bitbake.conf defaults it to ${UNPACKDIR}/${BP},
# where the git fetcher unpacks. Do NOT set S to anything mentioning WORKDIR —
# oe-core rejects it ("S should be set relative to UNPACKDIR") and that check
# scans the raw S string.

DEPENDS = "nlohmann-json"

inherit meson pkgconfig

