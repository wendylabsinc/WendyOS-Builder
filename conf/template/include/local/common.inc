# Shared build settings — required by every board.

DL_DIR = "${TOPDIR}/../downloads"

# RPi kernel source mirror. The self-hosted runner image bakes a bitbake mirror
# tarball of the 5+ GB raspberrypi/linux kernel tree at /opt/source-mirror
# (wendylabsinc/ci, seed-kernel-source-mirror.sh). Without this, the
# linux-raspberrypi do_fetch cold-clones that tree from GitHub at job time,
# which intermittently stalls / exits 128 and fails the RPi builds. Point
# PREMIRRORS at the baked tarball so the fetch is a local extract instead.
#
# Guarded on the directory existing, so local and dev builds (no mirror) are
# unaffected; if the tarball is ever absent, this is a PREMIRRORS (not
# BB_FETCH_PREMIRRORONLY), so bitbake still falls back to the upstream SRC_URI.
PREMIRRORS:prepend = "${@'git://github.com/raspberrypi/linux.* file:///opt/source-mirror/ \n' if os.path.isdir('/opt/source-mirror') else ''}"
# sstate-cache is partitioned per layer tree so cross-series builds (e.g.
# scarthgap Orin and wrynose Thor on the same workspace) don't share
# signatures or accidentally collide. Downloads stay shared — source
# tarballs are keyed by URL/checksum and reusable across series.
SSTATE_DIR = "${TOPDIR}/../sstate-cache/${WENDYOS_LAYER_TREE}"
#TMPDIR = "${TOPDIR}/tmp"
DISTRO = "wendyos"
#EXTRA_IMAGE_FEATURES ?= "debug-tweaks"
USER_CLASSES = "buildstats"
PATCHRESOLVE = "noop"

BB_DISKMON_DIRS ??= "\
    STOPTASKS,${TMPDIR},1G,100K \
    STOPTASKS,${DL_DIR},1G,100K \
    STOPTASKS,${SSTATE_DIR},1G,100K \
    STOPTASKS,/tmp,100M,100K \
    HALT,${TMPDIR},100M,1K \
    HALT,${DL_DIR},100M,1K \
    HALT,${SSTATE_DIR},100M,1K \
    HALT,/tmp,10M,1K"

# Per-recipe parallelism caps for the heavy native C++ compiles. The self-hosted
# builder runs each job in a container with a hard 16 GiB memory cgroup
# (MemoryMax=16G / MemoryHigh=14G, see wendylabsinc/ci); uncapped, these natives
# spawn enough cc1plus to blow past it and the cgroup OOM-killer takes out the
# compiler or the runner agent (surfaces as "runner lost communication").
#
# llvm-native and clang-native are x86-only: generic-x86-64 is the only board
# that pulls the LLVM/OpenCL graphics stack (mesa gallium-llvm + libclc, gated
# PACKAGECONFIG:append:x86-64), so they are never in an arm build and never in
# the shared sstate cache — x86 CI compiles both cold. At -j 4, plus x86's
# BB_NUMBER_THREADS cap (see x86.inc), the cold x86 stack peaks ~12 GiB. Both
# build under cmake/ninja, which honours PARALLEL_MAKE via
# CMAKE_BUILD_PARALLEL_LEVEL (cmake.bbclass).
PARALLEL_MAKE:pn-llvm-native = "-j 4"
PARALLEL_MAKE:pn-grpc-native = "-j 16"
PARALLEL_MAKE:pn-clang-native = "-j 4"

PACKAGECONFIG:append:pn-qemu-system-native = " sdl"
CONF_VERSION = "2"

# USB gadget function ordering (only effective when WENDYOS_USB_GADGET = "1")
#GADGET_FUNC_ORDER="ecm ncm"

# Debug/SSH defaults — off for production; opt in via auto.conf (bootstrap.sh
# --debug), local.conf, or board config. Uses ??= so bootstrap-generated
# auto.conf (parsed before local.conf per bitbake.conf) is not clobbered.
WENDYOS_DEBUG ??= "0"
WENDYOS_DEBUG_UART ??= "0"
WENDYOS_SSHD ??= "0"

# Local interactive login, split by console type — both default OFF on every
# image (a login prompt is pure attack surface). CI opts UART login in on PR
# builds only (see build.yml); enable either knob explicitly in local.conf or
# board config otherwise. UART/serial = serial-getty@ + console-getty on
# serial-console boards; VT = getty@ + autovt@ (+ console-getty on x86, where
# /dev/console is tty0). Root is never opened — log in as the wendy user
# (passwordless sudo).
WENDYOS_ENABLE_UART_LOGIN ??= "0"
WENDYOS_ENABLE_VT_LOGIN ??= "0"

# Build provenance stamped into the image (boot screen /etc/issue + /etc/wendyos/commit).
# CI overrides these in auto.conf per build: VERSION is the release/nightly/PR tag
# (pr-<N> | nightly-<ts> | X.Y.Z), COMMIT is the full builder git SHA. Local builds
# fall back to DISTRO_VERSION and an empty commit.
WENDYOS_BUILD_VERSION ??= "${DISTRO_VERSION}"
WENDYOS_BUILD_COMMIT ??= ""
