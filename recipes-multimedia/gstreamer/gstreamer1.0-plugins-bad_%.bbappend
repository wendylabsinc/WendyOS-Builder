# vulkan is auto-included via DISTRO_FEATURES but vulkansink requires a windowing
# system (x11 or wayland). WendyOS disables both, so meson hard-errors at configure.
PACKAGECONFIG:remove = "vulkan"

# frei0r gives GStreamer the frei0r-filter-* elements, of which the agent's
# thermal render mode needs normalize0r: a per-frame contrast stretch.
#
# Thermal cameras (TOPDON TC001 / InfiRay family, deployed on wendy-box-theta
# and ccr1) put a whole scene into ~16 of 256 grey levels, so an unprocessed
# frame renders as a flat grey rectangle in the CLI viewer, the console and the
# companion app. The stretch has to be per-frame: where that narrow band sits
# drifts with ambient temperature, and a fixed brightness/contrast stretch was
# measured clipping a real scene to a uniform field within minutes.
#
# `frei0r` is a PACKAGECONFIG on this recipe, so the wrapper plugin is built
# only when it is enabled here. Installing frei0r-plugins alone is NOT enough —
# without this the elements simply do not exist and the agent reports
# FailedPrecondition. `:append` matches the convention used elsewhere in this
# tree (see avahi_%.bbappend) so a weak default is not wiped.
PACKAGECONFIG:append = " frei0r"
