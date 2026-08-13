# WendyOS v4l2loopback kernel-contract include.
#
# WHY: the out-of-tree v4l2loopback module (recipe:
# meta-tegra-extensions-jp7/recipes-kernel/v4l2loopback/, shipped for
# WDY-2430 IP-camera container parity) is built against this kernel and
# links against its videodev (V4L2 core) and vb2-vmalloc (videobuf2 vmalloc
# allocator) symbols, gated by CONFIG_VIDEO_DEV and CONFIG_VIDEOBUF2_VMALLOC
# respectively. A kernel config change that drops either would otherwise
# surface only as an obscure module build/link failure deep inside the
# image build, with nothing pointing at the actual missing Kconfig option.
# This assertion runs in do_configure — right after Kconfig has resolved
# every BSP fragment and dependency — so a regression fails fast, at the
# point the config went wrong, with a named cause instead of a linker error
# several build stages later.
#
# This is the first kernel-contract include on main. An unmerged branch
# (agent/native-bluetooth-stack) establishes the same pattern for Bluetooth
# (recipes-kernel/linux/wendy-bluetooth.inc: a do_configure:append() symbol
# check plus a do_deploy:append() that publishes the checked config). Keep
# the shapes aligned when both merge — same "grep -Eq ^SYMBOL=(y|m)$ against
# ${B}/.config, bbfatal with a named symbol on failure" idiom. This include
# has no per-machine enable flag (unlike Bluetooth's opt-in
# WENDYOS_BLUETOOTH_ENABLE) because v4l2loopback is unconditionally
# RDEPENDS'd onto every Tegra image (packagegroup-wendyos-tegra.bb) — every
# board that pulls in this kernel bbappend needs the contract held.
#
# No SRC_URI kernel-config fragment here: CONFIG_VIDEO_DEV and
# CONFIG_VIDEOBUF2_VMALLOC are already enabled in NVIDIA's
# linux-noble-nvidia-tegra config (V4L2 is load-bearing for the CSI/ISP
# camera stack this BSP already ships, per the nvvideo4linux2/nvarguscamerasrc
# GStreamer plugins in conf/distro/include/tegra-image.inc). This assertion
# is a tripwire against a future regression, not an enabler — it does not
# turn anything on that isn't already on.

do_configure:append() {
    config="${B}/.config"
    [ -f "$config" ] || bbfatal "v4l2loopback: effective kernel config not found at $config"

    for symbol in CONFIG_VIDEO_DEV CONFIG_VIDEOBUF2_VMALLOC; do
        if ! grep -Eq "^${symbol}=(y|m)$" "$config"; then
            bbfatal "v4l2loopback: ${symbol} is neither built-in nor modular in $config — the out-of-tree module cannot build against this kernel"
        fi
    done
}

# Publish the exact config checked above beside the image artifacts, for
# postmortem debugging — same rationale and shape as wendy-bluetooth.inc's
# do_deploy:append(). Uses only DEPLOYDIR/MACHINE, which kernel.bbclass
# (via `inherit deploy`) already provides for every kernel recipe.
do_deploy:append() {
    install -m 0644 "${B}/.config" "${DEPLOYDIR}/wendyos-v4l2loopback-${MACHINE}.config"
}
