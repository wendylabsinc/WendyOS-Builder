# Shared build settings — required by every board.

DL_DIR = "${TOPDIR}/../downloads"
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

# Memory pressure management. The CI builders are c8id.8xlarge (32 vCPU /
# 64 GiB = only 2 GiB/core), and BitBake otherwise defaults BB_NUMBER_THREADS
# and PARALLEL_MAKE to nproc (32). The heavy native C++ compiles — notably
# llvm-native and grpc-native — spawn ~32 cc1plus processes that each peak
# well above 2 GiB, so on a cold sstate cache the kernel OOM-killer takes out
# the compiler ("g++: fatal error: Killed signal terminated program cc1plus")
# or starves the bitbake cooker ("No reply from server in 30s"). This only
# bit us once the blacksail series bumped to llvm 22.1.7 / grpc 1.80.0 with no
# cache to fall back on.
#
# BB_PRESSURE_MAX_MEMORY throttles scheduling of new tasks via the kernel's
# memory PSI (/proc/pressure/memory) so cross-recipe parallelism backs off
# under pressure, and the per-recipe PARALLEL_MAKE caps bound peak RSS within
# the two worst offenders. Both are cheap insurance — they only slow the
# first cold build of these natives; everything else stays cache-served.
BB_PRESSURE_MAX_MEMORY ?= "15000"
PARALLEL_MAKE:pn-llvm-native = "-j 16"
PARALLEL_MAKE:pn-grpc-native = "-j 16"

PACKAGECONFIG:append:pn-qemu-system-native = " sdl"
CONF_VERSION = "2"

# USB gadget function ordering (only effective when WENDYOS_USB_GADGET = "1")
#GADGET_FUNC_ORDER="ecm ncm"

# Debug/SSH defaults — off for production; opt in via auto.conf (bootstrap.sh
# --debug), local.conf, or board config. Uses ??= so bootstrap-generated
# auto.conf (parsed before local.conf per bitbake.conf) is not clobbered.
WENDYOS_DEBUG ??= "0"
WENDYOS_DEBUG_UART ??= "${WENDYOS_DEBUG}"
WENDYOS_SSHD ??= "0"

# Local interactive login, split by console type so each is opt-in separately.
# UART/serial login (serial-getty@ + console-getty on /dev/console) defaults to
# the WENDYOS_DEBUG value — kept on for debug images so the serial-login dev
# workflow survives, off for release. The monitor+keyboard VT login (getty@ +
# autovt@) defaults OFF on every image, debug included: it is not part of the
# dev workflow and is pure attack surface. Override either explicitly.
WENDYOS_ENABLE_UART_LOGIN ??= "${WENDYOS_DEBUG}"
WENDYOS_ENABLE_VT_LOGIN   ??= "0"

