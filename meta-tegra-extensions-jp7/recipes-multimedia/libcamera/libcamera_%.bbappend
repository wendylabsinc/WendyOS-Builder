# blacksail build fix.
#
# libcamera 0.7.1 (blacksail meta-multimedia) added a PACKAGECONFIG[opengl]
# that enables its GPU "softISP" path and DEPENDS on
# "virtual/libgl virtual/egl". Its PACKAGECONFIG default auto-enables that
# option whenever 'opengl' is in DISTRO_FEATURES (which wendyos sets, for
# TensorRT). On a headless Jetson there is no provider for virtual/libgl:
# meta-tegra points PREFERRED_PROVIDER_virtual/libgl at libglvnd, but
# libglvnd only PROVIDES virtual/libgl via its 'glx' PACKAGECONFIG, which
# requires the 'x11' DISTRO_FEATURE (GLX) — wrong for a headless device.
# Result: the wendyos-image dependency chain
# wireplumber -> pipewire -> libcamera -> virtual/libgl is unbuildable.
#
# The older wrynose libcamera had no opengl PACKAGECONFIG, so this is purely a
# 0.7.x regression for us. We don't use libcamera's CPU/GPU
# softISP (Jetson cameras go through NVIDIA's hardware ISP), so drop the
# option.
PACKAGECONFIG:remove = "opengl"
