# The STM32 on the UNO Q is wired to TLMM GPIOs. Arduino's OpenOCD fork, the one
# their own UNO Q image ships, has the linuxgpiod SWD adapter for libgpiod v2.
SRC_URI:arduino-uno-q-wendyos = " \
    git://github.com/facchinm/OpenOCD.git;protocol=https;name=openocd;nobranch=1 \
    git://github.com/msteveb/jimtcl.git;protocol=https;destsuffix=${BB_GIT_DEFAULT_DESTSUFFIX}/jimtcl;name=jimtcl;branch=master \
    "
SRCREV_openocd:arduino-uno-q-wendyos = "e6a2c12f41c9d1131b980c47af7517b4a5aca110"
SRCREV_jimtcl:arduino-uno-q-wendyos = "f160866171457474f7c4d6ccda70f9b77524407e"

DEPENDS:append:arduino-uno-q-wendyos = " libgpiod"
EXTRA_OECONF:append:arduino-uno-q-wendyos = " --enable-linuxgpiod"
PACKAGECONFIG:remove:arduino-uno-q-wendyos = "sysfsgpio"

# Machine-specific source, so it must not share a package arch with stock OpenOCD.
PACKAGE_ARCH:arduino-uno-q-wendyos = "${MACHINE_ARCH}"
