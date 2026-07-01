DESCRIPTION = "A fast and low-memory footprint OCI Container Runtime fully written in C."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=b234ee4d69f5fce4486a80fdaf4a4263"
PRIORITY = "optional"

# Vendored from meta-virtualization master (crun 1.28.0, 2026-05-27) because the
# scarthgap branch of meta-virtualization is frozen at crun v1.14.3 (2024-02-26).
# Shipping a ~2-year-old runtime as WendyOS's default OCI runtime is undesirable,
# so we pin the current release here and select it via PREFERRED_VERSION_crun in
# conf/distro/wendyos.conf. Revisit on the next meta-virtualization SRCREV bump:
# if upstream scarthgap gains a comparable crun, drop this recipe and its patches.
SRCREV_crun = "7e45b26ba9524290af70ffe645911f7e032d6913"
SRCREV_libocispec = "8034d0ecd27f646ba3ffae5ff24db234ce062825"
SRCREV_ispec = "13cff54902ec9ad6320cbc487a685b66fcd67171"
SRCREV_rspec = "6999a89a76a0329f440d5740497bedb9dd431297"
SRCREV_yajl = "f344d21280c3e4094919fd318bc5ce75da91fc06"

SRCREV_FORMAT = "crun_rspec"
# Use literal "git" destsuffixes and an explicit S (scarthgap style) rather than
# master's ${BB_GIT_DEFAULT_DESTSUFFIX} so this parses cleanly on scarthgap.
SRC_URI = "git://github.com/containers/crun.git;branch=main;name=crun;protocol=https \
           git://github.com/containers/libocispec.git;branch=main;name=libocispec;destsuffix=git/libocispec;protocol=https \
           git://github.com/opencontainers/runtime-spec.git;branch=main;name=rspec;destsuffix=git/libocispec/runtime-spec;protocol=https \
           git://github.com/opencontainers/image-spec.git;branch=main;name=ispec;destsuffix=git/libocispec/image-spec;protocol=https \
           git://github.com/containers/yajl.git;branch=main;name=yajl;destsuffix=git/libocispec/yajl;protocol=https \
           file://0001-libocispec-correctly-parse-JSON-schema-references.patch;patchdir=libocispec \
           file://0002-libocispec-fix-array-items-parsing.patch;patchdir=libocispec \
          "

PV = "1.28.0+git"
S = "${WORKDIR}/git"

inherit autotools-brokensep pkgconfig features_check

# crun ships a GNUmakefile that aborts if ./configure hasn't run yet,
# which breaks autotools_preconfigure's "make clean" on rebuild.
CLEANBROKEN = "1"

# WendyOS exposes crun under the "runc" name via update-alternatives in
# crun_%.bbappend (RPROVIDES virtual-runc, PROVIDES virtual/runc). Disable the
# recipe's own bare crun->runc symlink so it does not collide with the
# alternatives-managed ${bindir}/runc link.
CRUN_AS_RUNC = ""

PACKAGECONFIG ??= " \
    caps external-yajl man \
    ${@bb.utils.contains('DISTRO_FEATURES', 'seccomp', 'seccomp', '', d)} \
    ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'systemd', '', d)} \
"

PACKAGECONFIG[caps] = "--enable-caps,--disable-caps,libcap"
PACKAGECONFIG[external-yajl] = "--disable-embedded-yajl,--enable-embedded-yajl,yajl"
# whether to regenerate manpages that are already present in the repo
PACKAGECONFIG[man] = ",,go-md2man-native"
PACKAGECONFIG[seccomp] = "--enable-seccomp,--disable-seccomp,libseccomp"
PACKAGECONFIG[systemd] = "--enable-systemd,--disable-systemd,systemd"

DEPENDS = "m4-native json-c"
DEPENDS:append:libc-musl = " argp-standalone"

do_configure:prepend () {
    # extracted from autogen.sh in crun source. This avoids
    # git submodule fetching.
    mkdir -p m4
    autoreconf -fi
}

do_install() {
    oe_runmake 'DESTDIR=${D}' install
    if [ -n "${CRUN_AS_RUNC}" ]; then
        ln -sr "${D}/${bindir}/crun" "${D}${bindir}/runc"
    fi
}

# When crun provides /usr/bin/runc symlink, it conflicts with the runc package
RCONFLICTS:${PN} = "${@'runc' if d.getVar('CRUN_AS_RUNC') else ''}"

REQUIRED_DISTRO_FEATURES:class-native ?= ""
DEPENDS:class-native += "yajl libcap go-md2man m4 libseccomp"
BBCLASSEXTEND = "native"
