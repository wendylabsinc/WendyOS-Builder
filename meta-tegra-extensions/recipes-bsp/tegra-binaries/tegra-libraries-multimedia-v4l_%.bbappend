# Give containers the hardware video decoder plugin.
#
# Inside an Ubuntu container, NVIDIA's libv4l2 loads its plugins only from
# /usr/lib/aarch64-linux-gnu/libv4l/plugins/nv/. This recipe installs the
# decoder plugin only to the device's own folder, ${libdir}/libv4l/plugins/.
# meta-tegra's tegra-container-passthrough recipe lays out the Ubuntu folders
# under /usr/share/nvidia-container-passthrough, but copies in only the camera
# plugin, not the decoder plugin.
#
# This copies the decoder plugin for the board's chip (TEGRA_PLUGINS: one file
# on Thor, another on Orin) into that same folder, the same way the camera
# plugin is laid out there: a real file in nvidia/, and a relative link to it
# in libv4l/plugins/nv/. The file must be a real copy. A link to /usr/lib
# would not resolve when the container setup reads the folder as an
# alternate root. meta-tegra's drivers.csv already names both paths, and our
# container setup service passes this folder with --alt-roots, so both reach
# containers without a list change.
#
# Delete this file once meta-tegra's tegra-container-passthrough recipe ships
# the decoder plugin. It did not on the upstream blacksail and master
# branches, checked 2026-11-01.

do_install:append() {
    install -d ${D}${datadir}/nvidia-container-passthrough/usr/lib/aarch64-linux-gnu/nvidia
    install -d ${D}${datadir}/nvidia-container-passthrough/usr/lib/aarch64-linux-gnu/libv4l/plugins/nv
    for f in ${TEGRA_PLUGINS}; do
        install -m 0644 ${S}/usr/lib/aarch64-linux-gnu/nvidia/$f \
            ${D}${datadir}/nvidia-container-passthrough/usr/lib/aarch64-linux-gnu/nvidia/$f
        ln -sf ../../../nvidia/$f \
            ${D}${datadir}/nvidia-container-passthrough/usr/lib/aarch64-linux-gnu/libv4l/plugins/nv/$f
    done
}

# Only the plugin files, not the whole folder: tegra-container-passthrough
# owns the rest of it.
FILES:${PN} += " \
    ${@' '.join('${datadir}/nvidia-container-passthrough/usr/lib/aarch64-linux-gnu/nvidia/' + f for f in d.getVar('TEGRA_PLUGINS').split())} \
    ${@' '.join('${datadir}/nvidia-container-passthrough/usr/lib/aarch64-linux-gnu/libv4l/plugins/nv/' + f for f in d.getVar('TEGRA_PLUGINS').split())} \
    "
