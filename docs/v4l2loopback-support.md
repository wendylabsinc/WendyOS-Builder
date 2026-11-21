# V4L2 and ALSA loopback support

WendyOS includes `v4l2loopback` on Tegra, Qualcomm, Raspberry Pi and VM images.
The agent uses its control device to create virtual cameras for IP cameras and
SensorLink sources. Qualcomm, Raspberry Pi and VM images also include `snd-aloop`,
which exposes SensorLink microphones through ALSA PCM devices.

## Packages and loading

The shared recipe is `recipes-kernel/v4l2loopback/v4l2loopback_0.15.4.bb`.
It builds against the target kernel through `inherit module`. Its source pin
stays at `0f9ee86760b7f2bea174b7e3e7a1d38845da0ab4`, the v0.15.4 tag.
The agent's ioctl definitions match that version. Upstream changed the public
ioctl numbers and structure layout in v0.15.0, so a future version change
must check the agent's definitions against the new header.

Tegra images require the package through `packagegroup-wendyos-tegra`.
`qcom-image.inc` explicitly installs `v4l2loopback` and
`kernel-module-snd-aloop` on every `qcom-wendyos` target, including Uno Q.
`rpi-image.inc` does the same on every `rpi` target (Pi 3, Pi 4 and Pi 5).
`vm-image.inc` explicitly installs both loopback drivers for both VM
architectures. Their linux-yocto append includes the shared `virtual-loopback.cfg` fragment: it enables camera support
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
