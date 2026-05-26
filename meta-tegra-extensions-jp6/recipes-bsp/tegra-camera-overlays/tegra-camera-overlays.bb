SUMMARY = "Camera DT overlays for Jetson Orin (IMX477/IMX219)"
DESCRIPTION = "Promotes selected NVIDIA-built camera device-tree overlay .dtbo \
files into /boot/ so the L4TLauncher extlinux OVERLAYS directive can apply \
them at boot, exposing ribbon-camera sensor nodes to the kernel. The actual \
.dtbo files are produced upstream by nvidia-kernel-oot's 'oe_runmake dtbs' \
build target and exposed via its sysroot under /boot/devicetree/. \
\
Scoped to tegra234 (JetPack 6 / Orin family). Thor (tegra264 / JP7) is \
deferred — see WDY-1249."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "(tegra234)"

PACKAGE_ARCH = "${MACHINE_ARCH}"

DEPENDS += "nvidia-kernel-oot"

# Selected overlays to promote to /boot/. Each name must match a file
# emitted by nvidia-kernel-oot under ${RECIPE_SYSROOT}/boot/devicetree/.
# Activation (the OVERLAYS line in extlinux.conf) is controlled
# separately by UBOOT_EXTLINUX_FDTOVERLAYS:<machine> in
# meta-tegra-extensions/recipes-bsp/uefi/l4t-launcher-extlinux.bbappend —
# shipping a .dtbo here does not by itself enable it at boot.
TEGRA_CAMERA_OVERLAYS ?= ""
TEGRA_CAMERA_OVERLAYS:jetson-orin-nano-devkit = "\
    tegra234-p3768-camera-rbpcv3-imx477.dtbo \
    tegra234-p3768-camera-rbpcv2-imx219.dtbo \
    tegra234-p3768-camera-imx219-imx477.dtbo \
"
TEGRA_CAMERA_OVERLAYS:jetson-agx-orin-devkit = "\
    tegra234-p3737-camera-imx274.dtbo \
"

S = "${WORKDIR}"

do_install() {
    install -d ${D}/boot
    staged="${RECIPE_SYSROOT}/boot/devicetree"
    if [ -z "${TEGRA_CAMERA_OVERLAYS}" ]; then
        bbnote "No overlays selected for MACHINE=${MACHINE}; skipping."
        return 0
    fi
    for ov in ${TEGRA_CAMERA_OVERLAYS}; do
        src="${staged}/${ov}"
        if [ ! -f "$src" ]; then
            available=$(cd "${staged}" 2>/dev/null && ls *camera*.dtbo 2>/dev/null | tr '\n' ' ')
            bbfatal "Overlay '${ov}' not found at $src. \
nvidia-kernel-oot did not emit this file. Available camera overlays: ${available:-none}"
        fi
        install -m 0644 "$src" ${D}/boot/${ov}
    done
}

FILES:${PN} = "/boot/*.dtbo"
