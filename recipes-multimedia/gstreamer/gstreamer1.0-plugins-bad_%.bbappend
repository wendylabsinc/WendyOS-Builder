# vulkan is auto-included via DISTRO_FEATURES but vulkansink requires a windowing
# system (x11 or wayland). WendyOS disables both, so meson hard-errors at configure.
PACKAGECONFIG:remove = "vulkan"
