# Headless/container deployment fixups for DeepStream 8.0 (blacksail / JP7.2).
#
# Kept in a bbappend (NOT the recipe) so they apply by PN regardless of which
# layer provides the deepstream-8.0 recipe. Today they apply to our interim
# meta-tegra-extensions-jp7/recipes-devtools/deepstream/deepstream-8.0_*.bb;
# when meta-tegra-community ships an upstream deepstream-8.0, delete that .bb
# and these fixups keep applying to the upstream recipe with no other changes.
#
# Mirrors meta-tegra-extensions-jp6/recipes-devtools/deepstream/deepstream-7.1_%.bbappend
# (path -> deepstream-8.0).

# Skip X11 dependency for headless/container use — DeepStream ships some
# X11-linked binaries we do not need, and the prebuilt libs trip OE's
# file-rdeps QA.
INSANE_SKIP:${PN} += "file-rdeps"
INSANE_SKIP:${PN}-samples += "file-rdeps"

# Prevent automatic dependency detection from adding X11 libs.
PRIVATE_LIBS:${PN} = "libX11.so.6"
PRIVATE_LIBS:${PN}-samples = "libX11.so.6"

# Skip FILEDEPS scanning for these packages to avoid RPM dep generation.
SKIP_FILEDEPS:${PN} = "1"
SKIP_FILEDEPS:${PN}-samples = "1"

# Fix the missing libcivetweb.so.1 symlink (required by the GStreamer plugins);
# the deb ships only libcivetweb.so + libcivetweb.so.1.16.0. Path hardcoded so
# this does not depend on the recipe defining DEEPSTREAM_PATH.
do_install:append() {
    if [ -f ${D}/opt/nvidia/deepstream/deepstream-8.0/lib/libcivetweb.so.1.16.0 ]; then
        cd ${D}/opt/nvidia/deepstream/deepstream-8.0/lib
        ln -sf libcivetweb.so.1.16.0 libcivetweb.so.1
    fi
}
