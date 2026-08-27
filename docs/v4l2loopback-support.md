# v4l2loopback support

WendyOS ships the out-of-tree [v4l2loopback](https://github.com/v4l2loopback/v4l2loopback)
kernel module on every Jetson image for IP-camera container parity
(WDY-2430): it gives any container that only knows how to open a V4L2
device a way to consume a network camera transparently, by letting the
WendyAgent device agent decode an RTSP stream and feed the frames into a
virtual `/dev/video<nr>` capture node instead of a real one.

## What ships

- **Module**: `v4l2loopback_0.15.4.bb`
  (`meta-tegra-extensions-jp7/recipes-kernel/v4l2loopback/`), built
  out-of-tree against `linux-noble-nvidia-tegra` (kernel 6.8) via
  `inherit module`. The recipe pins an exact upstream commit with
  `SRCREV = "0f9ee86760b7f2bea174b7e3e7a1d38845da0ab4"` (the v0.15.4 tag) —
  not a floating branch head — because, as covered below, the module's
  public ioctl ABI is a contract the agent code depends on.
- **Autoload**: `KERNEL_MODULE_AUTOLOAD` has
  `kernel-module-split.bbclass` generate a `modules-load.d/v4l2loopback.conf`
  file in the module package, so its control device exists before the agent
  starts adding per-camera nodes.
- **Options**: `KERNEL_MODULE_PROBECONF` similarly generates a
  `modprobe.d/v4l2loopback.conf` file that pins `devices=0`:
  - `devices=0` boots the module with only the control device
    (`/dev/v4l2loopback`) and no stray `/dev/video0` — the agent creates
    every capture node itself via ioctl, and a phantom device 0 would
    collide with real camera enumeration.
  - The module-level `exclusive_caps` parameter applies only to devices
    created while the module initializes, so it has no effect when
    `devices=0`. The agent instead sets `announce_all_caps=0` in each
    `V4L2LOOPBACK_CTL_ADD` request, making that device announce OUTPUT xor
    CAPTURE capabilities (never both), as consumers such as GStreamer and
    ffmpeg expect.
- Unconditionally RDEPENDS'd onto every Tegra image via
  `packagegroup-wendyos-tegra.bb` — the recipe only exists in the
  blacksail (JP7.2) layer tree, but every current Tegra board builds
  blacksail, so there is no per-board gate.

## The kernel contract

The module links against the running kernel's `videodev` (V4L2 core) and
`vb2-vmalloc` (videobuf2 vmalloc allocator) symbols, gated by
`CONFIG_VIDEO_DEV` and `CONFIG_VIDEOBUF2_VMALLOC`. Both are already enabled
in NVIDIA's kernel config — V4L2 is load-bearing for the CSI/ISP camera
stack this BSP ships regardless (the `nvvideo4linux2` /
`nvarguscamerasrc` GStreamer plugins depend on it too) — so nothing needs
to be turned on for v4l2loopback specifically.

What *can* happen is a future kernel bump or config change silently
dropping one of those symbols, which would otherwise surface only as an
obscure module build/link failure deep inside the image build, with
nothing pointing at the actual missing Kconfig option. To fail fast
instead, the `v4l2loopback_0.15.4.bb` module recipe adds a
`do_configure:append()` that reads the effective
`${STAGING_KERNEL_BUILDDIR}/.config` after Kconfig has resolved every BSP
fragment and dependency, and `bbfatal`s with a named symbol if either is
missing:

```sh
for symbol in CONFIG_VIDEO_DEV CONFIG_VIDEOBUF2_VMALLOC; do
    grep -Eq "^${symbol}=(y|m)$" "${STAGING_KERNEL_BUILDDIR}/.config" || bbfatal "..."
done
```

This is a tripwire, not an enabler — the recipe carries no `SRC_URI`
kernel-config fragment. Keeping the assertion in the module recipe also
means changes to the check do not invalidate the shared Tegra kernel's
sstate across every machine.

## The consumer

WendyAgent owns everything past the control device. For each configured
IP camera it opens `/dev/v4l2loopback` and issues `V4L2LOOPBACK_CTL_ADD` to
create a pinned-number capture node in the `/dev/video200`–`/dev/video255`
range (kept well clear of real camera enumeration, which starts at
`/dev/video0`), then writes decoded RTSP frames into it.

This is why the module version is pinned by exact `SRCREV` rather than
tracking `main`: upstream's 0.15.0 release changed the public ioctl
numbers and struct layout ("change public ioctl numbers!" in their
ChangeLog) relative to the 0.13.x/0.14.x line. The agent's ioctl struct
definitions must be generated from this exact pinned revision's
`v4l2loopback.h`, not an older or newer one — bumping `SRCREV` past an ABI
boundary without regenerating the agent-side headers would silently
corrupt the control-device protocol.

## On-device smoke test

```sh
# Module loaded, control device only (devices=0 means no /dev/video0 here)
lsmod | grep v4l2loopback
ls -l /dev/v4l2loopback

# After the agent has added at least one camera node:
v4l2-ctl --list-devices
```

`v4l2-ctl` ships in every Tegra image via `v4l-utils`
(`conf/distro/include/tegra-image.inc`), so no extra package install is
needed on-device. `v4l2-ctl --list-devices` should list the loopback
device(s) the agent created, each showing its exclusive OUTPUT or CAPTURE
capability per the add request's `announce_all_caps=0` setting.
