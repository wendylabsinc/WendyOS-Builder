# Ported verbatim from meta-raspberrypi master (commit 0e56e2f, "libpisp:
# Upgrade to 1.3.0 release"). The meta-raspberrypi revision WendyOS pins
# (SRCREV_RPI in scripts/upstream-repos.env, scarthgap branch) predates
# upstream PiSP support: libpisp and the libcamera rpi/pisp pipeline only
# landed on meta-raspberrypi master/whinlatter, not on scarthgap. The
# Raspberry Pi 5 camera path (BCM2712 + RP1 CFE) requires the PiSP backend,
# whose libcamera pipeline handler links against libpisp, so we carry the
# recipe here. Drop this file once SRCREV_RPI is bumped to a rev that ships
# libpisp under recipes-multimedia/libpisp.
DESCRIPTION = "A helper library to generate run-time configuration for the Raspberry Pi \
ISP (PiSP), consisting of the Frontend and Backend hardware components."
HOMEPAGE = "https://github.com/raspberrypi/libpisp"
LICENSE = "BSD-2-Clause & GPL-2.0-only & GPL-2.0-or-later"
LIC_FILES_CHKSUM = "file://LICENSE;md5=3417a46e992fdf62e5759fba9baef7a7 \
                    file://LICENSES/GPL-2.0-only.txt;md5=b234ee4d69f5fce4486a80fdaf4a4263 \
                    file://LICENSES/GPL-2.0-or-later.txt;md5=fed54355545ffd980b814dab4a3b312c"

# Pin by SRCREV only. Upstream tags v1.3.0 at exactly this commit, but the
# scarthgap bitbake fetcher rejects a git url that carries both tag= and an
# explicit SRCREV ("Conflicting revisions ... please specify one valid value").
# meta-raspberrypi master keeps tag=v${PV} because its newer bitbake resolves
# and cross-checks the two; the older bitbake WendyOS pins does not.
SRC_URI = "git://github.com/raspberrypi/libpisp.git;protocol=https;branch=main"
SRCREV = "9ba67e6680f03f31f2b1741a53e8fd549be82cbe"

# Explicit S for git fetches: unlike meta-raspberrypi master (which runs on a
# newer bitbake), the bitbake revision WendyOS pins does not default S to the
# git checkout dir. Matches libcamera_0.4.0.bb / libcamera-apps_git.bb here.
S = "${WORKDIR}/git"

DEPENDS = "nlohmann-json"

inherit meson pkgconfig
