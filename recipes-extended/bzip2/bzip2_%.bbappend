# sourceware.org gates git access behind an Anubis anti-scraper challenge that
# bitbake's fetcher cannot solve, so do_fetch fails. ptest is already removed
# from DISTRO_FEATURES in wendyos.conf, so the bzip2-tests sources are unused —
# drop them from SRC_URI and the license manifest, and disable ptest for this
# recipe explicitly so a future DISTRO_FEATURES change doesn't silently break
# do_install_ptest.
#
# Both scarthgap and wrynose forms are listed because the URI string and the
# LIC_FILES_CHKSUM paths differ between series (wrynose adds ;destsuffix= and
# uses ${UNPACKDIR}; scarthgap uses ${WORKDIR}/git). A :remove token that
# doesn't match anything is a harmless no-op.

SRC_URI:remove = " \
    git://sourceware.org/git/bzip2-tests.git;name=bzip2-tests;branch=master;protocol=https \
    git://sourceware.org/git/bzip2-tests.git;name=bzip2-tests;branch=master;protocol=https;destsuffix=bzip2-tests/ \
    "

LIC_FILES_CHKSUM:remove = " \
    file://${WORKDIR}/git/commons-compress/LICENSE.txt;md5=86d3f3a95c324c9479bd8986968f4327 \
    file://${WORKDIR}/git/dotnetzip/License.txt;md5=9cb56871eed4e748c3bc7e8ff352a54f \
    file://${WORKDIR}/git/dotnetzip/License.zlib.txt;md5=cc421ccd22eeb2e5db6b79e6de0a029f \
    file://${WORKDIR}/git/go/LICENSE;md5=5d4950ecb7b26d2c5e4e7b4e0dd74707 \
    file://${WORKDIR}/git/lbzip2/COPYING;md5=d32239bcb673463ab874e80d47fae504 \
    file://${UNPACKDIR}/bzip2-tests/commons-compress/LICENSE.txt;md5=86d3f3a95c324c9479bd8986968f4327 \
    file://${UNPACKDIR}/bzip2-tests/dotnetzip/License.txt;md5=9cb56871eed4e748c3bc7e8ff352a54f \
    file://${UNPACKDIR}/bzip2-tests/dotnetzip/License.zlib.txt;md5=cc421ccd22eeb2e5db6b79e6de0a029f \
    file://${UNPACKDIR}/bzip2-tests/go/LICENSE;md5=5d4950ecb7b26d2c5e4e7b4e0dd74707 \
    file://${UNPACKDIR}/bzip2-tests/lbzip2/COPYING;md5=d32239bcb673463ab874e80d47fae504 \
    "

PTEST_ENABLED = "0"
