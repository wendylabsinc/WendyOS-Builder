# V4L2 and ALSA loopback support

WendyOS includes `v4l2loopback` on Tegra and Qualcomm images. The agent uses
its control device to create virtual cameras for IP cameras and SensorLink
sources. Qualcomm images also include `snd-aloop`, which exposes SensorLink
microphones through ALSA PCM devices.

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

## Build checks

The module recipe checks the effective kernel configuration for
`CONFIG_VIDEO_DEV` and `CONFIG_VIDEOBUF2_VMALLOC`. The Qualcomm kernel
append also checks those settings and requires `CONFIG_SND_ALOOP=m`
after Kconfig resolves its fragments.

After `do_rootfs` generates `modules.dep`, `sensor-loopback-check.bbclass`
validates each Qualcomm image. It checks both loopback driver files and
every module dependency against the compiled kernel release. A module tree
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
