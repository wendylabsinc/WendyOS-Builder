SUMMARY = "NVIDIA Container Configuration for Jetson"
DESCRIPTION = "Provides l4t.csv configuration, CDI spec generation, and CUDA environment detection for NVIDIA GPU containers"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

# DeepStream support flag (default off)
WENDYOS_DEEPSTREAM ?= "0"

SRC_URI = " \
    file://l4t.csv \
    file://l4t-blacksail.csv \
    file://l4t-deepstream.csv \
    file://l4t-deepstream-blacksail.csv \
    file://devices-wendyos.csv \
    file://wendyos-cdi-generate.service \
    file://wendyos-cuda-detect.service \
    file://generate-cuda-env.sh \
    file://99-z-nvidia-tegra.rules \
    file://fix-cdi-gstreamer-paths.sh \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "wendyos-cdi-generate.service wendyos-cuda-detect.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Install CSV files to the NVIDIA container runtime config directory
    install -d ${D}${sysconfdir}/nvidia-container-runtime/host-files-for-container.d

    # Install base l4t.csv (CUDA/PyTorch container libraries). Host paths are
    # BSP-specific, so two variants (same pattern as the DeepStream CSV):
    #   scarthgap/JP6   -> l4t.csv           (CUDA 12.6 + cuDNN 9.3.0)
    #   blacksail/JP7.2 -> l4t-blacksail.csv (CUDA 13.2 + cuDNN 9.20.0)
    # Both install under the same target name so exactly one is active.
    if [ "${WENDYOS_LAYER_TREE}" = "blacksail" ]; then
        basecsv="l4t-blacksail.csv"
    else
        basecsv="l4t.csv"
    fi
    install -m 0644 ${UNPACKDIR}/${basecsv} ${D}${sysconfdir}/nvidia-container-runtime/host-files-for-container.d/l4t.csv

    # Install DeepStream CSV if enabled
    if [ "${WENDYOS_DEEPSTREAM}" = "1" ]; then
        # CUDA/DeepStream host paths are BSP-specific, so we ship two CSVs:
        #   scarthgap/JP6   -> l4t-deepstream.csv           (CUDA 12.6 + DeepStream 7.1)
        #   blacksail/JP7.2 -> l4t-deepstream-blacksail.csv (CUDA 13.2 + DeepStream 8.0)
        # Both install under the same target name so exactly one is active.
        if [ "${WENDYOS_LAYER_TREE}" = "blacksail" ]; then
            dscsv="l4t-deepstream-blacksail.csv"
        else
            dscsv="l4t-deepstream.csv"
        fi
        bbnote "Installing DeepStream CSV: ${dscsv}"
        install -m 0644 ${UNPACKDIR}/${dscsv} ${D}${sysconfdir}/nvidia-container-runtime/host-files-for-container.d/l4t-deepstream.csv

        # Create multiarch compatibility symlinks for GStreamer DeepStream plugins
        # This allows the CDI GST_PLUGIN_PATH to work with both Yocto and Debian/Ubuntu conventions
        install -d ${D}${libdir}/aarch64-linux-gnu/gstreamer-1.0
        ln -sf ../../gstreamer-1.0/deepstream ${D}${libdir}/aarch64-linux-gnu/gstreamer-1.0/deepstream

        # Create multiarch symlink for nvidia libraries (libgstnvcustomhelper.so, etc.)
        install -d ${D}${libdir}/aarch64-linux-gnu
        ln -sf ../nvidia ${D}${libdir}/aarch64-linux-gnu/nvidia
    fi

    # Install WendyOS device/sysfs mappings (supplements meta-tegra's devices.csv)
    install -m 0644 ${UNPACKDIR}/devices-wendyos.csv ${D}${sysconfdir}/nvidia-container-runtime/host-files-for-container.d/

    # Install CUDA environment detection script
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/generate-cuda-env.sh ${D}${bindir}/

    # Install CDI post-processing script for DeepStream path fixes
    install -m 0755 ${UNPACKDIR}/fix-cdi-gstreamer-paths.sh ${D}${bindir}/

    # Install systemd services
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-cdi-generate.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/wendyos-cuda-detect.service ${D}${systemd_system_unitdir}/

    # Install udev rules for GPU device permissions (z- prefix ensures it runs last)
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/99-z-nvidia-tegra.rules ${D}${sysconfdir}/udev/rules.d/

    # Create directory for CUDA environment file
    install -d ${D}${sysconfdir}/default
}

FILES:${PN} += "${sysconfdir}/nvidia-container-runtime/host-files-for-container.d/l4t.csv"
FILES:${PN} += "${sysconfdir}/nvidia-container-runtime/host-files-for-container.d/l4t-deepstream.csv"
FILES:${PN} += "${sysconfdir}/nvidia-container-runtime/host-files-for-container.d/devices-wendyos.csv"
FILES:${PN} += "${bindir}/generate-cuda-env.sh"
FILES:${PN} += "${bindir}/fix-cdi-gstreamer-paths.sh"
FILES:${PN} += "${systemd_system_unitdir}/wendyos-cdi-generate.service"
FILES:${PN} += "${systemd_system_unitdir}/wendyos-cuda-detect.service"
FILES:${PN} += "${sysconfdir}/udev/rules.d/99-z-nvidia-tegra.rules"

# Multiarch compatibility symlinks (only when DeepStream is enabled)
FILES:${PN} += "${@bb.utils.contains('WENDYOS_DEEPSTREAM', '1', '${libdir}/aarch64-linux-gnu/gstreamer-1.0/deepstream', '', d)}"
FILES:${PN} += "${@bb.utils.contains('WENDYOS_DEEPSTREAM', '1', '${libdir}/aarch64-linux-gnu/nvidia', '', d)}"

# nvidia-container-toolkit is now available via meta-tegra virtualization layer
RDEPENDS:${PN} = "nvidia-container-toolkit libnvidia-container bash"
