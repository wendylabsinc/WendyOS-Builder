# V4L2 and ALSA loopback support

WendyOS includes `v4l2loopback` on Tegra, Qualcomm, Raspberry Pi, Rockchip and VM images.
The agent uses its control device to create virtual cameras for IP cameras and
SensorLink sources. Qualcomm, Raspberry Pi, Rockchip and VM images also include `snd-aloop`,
which exposes SensorLink microphones through ALSA PCM devices.

## Packages and loading

The shared recipe is `recipes-kernel/v4l2loopback/v4l2loopback_0.15.4.bb`.
It builds against the target kernel through `inherit module`. Its source pin
stays at `0f9ee86760b7f2bea174b7e3e7a1d38845da0ab4`, the v0.15.4 tag.
The agent's ioctl definitions match that version. Upstream changed the public
ioctl numbers and structure layout in v0.15.0, so a future version change
must check the agent's definitions against the new header.

The shared recipe applies the OUTPUT completion queue correction described in
`v4l2-output-queue-candidate.md`, followed by `0002-fresh-capture-start.patch`.
Both patches apply to every machine using this recipe, including VM images.

The second patch adds an optional boolean V4L2 control, `fresh_start`
(`0x0098f904`, default `0`). When enabled, each new CAPTURE `STREAMON` anchors
that reader to the current producer position before publishing capture demand.
Its first successful read/dequeue requires a subsequent producer write.
Retained frames, sustain-framerate repeats and timeout images cannot satisfy
that first read. After the first real frame, normal sustain and timeout behavior
resumes. Repeated `STREAMON` on an already active reader does not discard queued
frames; `STREAMOFF` followed by `STREAMON` starts a fresh interval. The `read(2)`
path uses the same rule through its lazy stream startup. After `S_FMT`, `poll`
also starts that stream when STREAMON can succeed (a writer is streaming or
`keep_format` is set), so such a reader does not wake for an old frame.
The ID `0x0098f904` is an ABI shared with the agent. Keep it when rebasing,
even if upstream later defines its own control at `V4L2LOOPBACK_CID_BASE + 4`.

Demand-driven camera sharing enables this control before exposing a node to an
app. Agents must check control support and report camera sharing unavailable on
an older module; writing a blank frame is not a substitute for fresh capture.

The control is opt-in, but the patches also change these defaults for every
loopback user, to match the kernel's videobuf2 framework:

- A signal interrupts a capture `DQBUF` or `read(2)` that is waiting for a frame
  (`EINTR`, or a restart with `SA_RESTART`). Upstream returned a repeated frame.
- An MMAP writer's `poll` reports `POLLOUT` only while a completed buffer waits
  to be dequeued. Writers queue their buffers before they poll.
- `STREAMOFF` ends a `DQBUF` that is waiting on either queue with `EINVAL`, and
  a blocking OUTPUT `DQBUF` on a stopped queue returns `EINVAL`. A nonblocking
  `DQBUF` with nothing ready still returns `EAGAIN`.

Before releasing these patches, run the real Linux camera-sharing fixture from
[WendyOS #3011](https://github.com/wendylabsinc/WendyOS/pull/3011) against this
exact source revision and patch pair. Require first-frame pixel checks for new
readers, same-descriptor restart, late peers and producer restart, including
no-frame blocking and sustain/timeout readiness. Then share a real camera on one
Tegra, one Qualcomm and one Raspberry Pi board. Check a new reader's first
frame, a reader restart, and that an app stops cleanly while it waits for a
frame.
Compile and patch-application checks alone do not establish these runtime
guarantees. Rollback requires removing the patches from `SRC_URI` and rebuilding
matching OS images; newer agents then take their unsupported-control fallback.

Tegra images require the package through `packagegroup-wendyos-tegra`.
`qcom-image.inc` explicitly installs `v4l2loopback` and
`kernel-module-snd-aloop` on every `qcom-wendyos` target, including Uno Q.
`rpi-image.inc` does the same on every `rpi` target (Pi 3, Pi 4 and Pi 5).
`vm-image.inc` explicitly installs both loopback drivers for both VM
architectures, and `rockchip-image.inc` for every `rockchip-wendyos` board.
Both linux-yocto appends include the shared `virtual-loopback.cfg` fragment: it enables camera support
and the USB webcam (UVC) driver, plus `CONFIG_SND_ALOOP=m`. Media and sound
stay at each board's own setting, module or built-in. The agent loads ALSA
loopback on demand.
These are required image packages. Missing drivers fail the image build.

The v4l2loopback recipe generates module loading and modprobe configuration
with `devices=0`. Boot loads only `/dev/v4l2loopback`; the agent creates
numbered `/dev/video*` nodes through `V4L2LOOPBACK_CTL_ADD`. This avoids
creating a spare `/dev/video0` which could collide with camera enumeration.
The agent sets `announce_all_caps=0` per virtual camera for exclusive
OUTPUT or CAPTURE capabilities. The module's `exclusive_caps` parameter
only affects devices created during module initialization.

The agent loads `snd-aloop` on demand using `modprobe snd-aloop`.
The Qualcomm kernel fragment preserves the BSP's modular sound and media
stacks and requires `CONFIG_SND_ALOOP=m`. ALSA selects the PCM and timer
dependencies. No ALSA card is created by an additional boot autoload rule.
Raspberry Pi kernels need no fragment: the RPi defconfigs set
`CONFIG_SND_ALOOP=m` and build media support as modules with the media filter
off. Camera support and `CONFIG_VIDEO_DEV=m` then follow by default.

## Build checks

The module recipe checks the effective kernel configuration for
`CONFIG_VIDEO_DEV`. v4l2loopback uses only the V4L2 core (`videodev`). It
keeps its own frame buffers and does not use the videobuf2 allocator. The
Qualcomm kernel append also checks `CONFIG_VIDEO_DEV` and requires
`CONFIG_SND_ALOOP=m` after Kconfig resolves its fragments. VM kernels
separately check `CONFIG_VIDEO_DEV` and modular `CONFIG_SND_ALOOP` after
configuration.
Existing simulator disks need a rebuilt matching image or OTA update; changing
the image recipe does not install a module into a running simulator.

After `do_rootfs` generates `modules.dep`, `sensor-loopback-check.bbclass`
validates each Qualcomm, Raspberry Pi and VM image. It checks both loopback
driver files and every module dependency against the compiled kernel
release. A module tree
for a different kernel, a missing dependency, or an absent driver fails
before image and OTA artifacts are produced. This catches the IQ9 failure
where the kernel enabled ALSA loopback but the image omitted its package,
and v4l2loopback was available only to the Tegra layer.

Run the fixture tests without a Yocto build:

```sh
python3 -m unittest scripts/check_sensor_loopback_support_test.py scripts/check_mesh_kernel_support_test.py
```

For the IQ9 image, build with `BOARD=dragonwing-iq9075` using the normal
builder setup. The kernel and rootfs checks run as part of that build.
The fixture tests do not replace a target kernel build or device validation.

## Device validation

After installing the matching image, the agent should find
`/dev/v4l2loopback`, mount the paired camera channels, and load `snd-aloop`
when it mounts a microphone channel. Confirm the pairing reports connected
and the consuming application receives camera frames or microphone samples.
Successful module loading alone does not establish that sensor data arrives.
