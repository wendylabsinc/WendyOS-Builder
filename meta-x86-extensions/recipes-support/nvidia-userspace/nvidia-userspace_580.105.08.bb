SUMMARY = "NVIDIA proprietary GPU userspace (CUDA driver, NVML, nvidia-smi) + GSP firmware"
DESCRIPTION = "Prebuilt userspace extracted from NVIDIA's .run installer: the CUDA \
driver (libcuda), management library (libnvidia-ml/NVML), nvidia-smi and the GSP \
firmware the open kernel modules load to bring up a Blackwell GPU. Must be the exact \
same PV as nvidia-open-kmod — the kernel modules and this userspace are one ABI."
HOMEPAGE = "https://www.nvidia.com"

LICENSE = "NVIDIA-Proprietary"
# NVIDIA Driver License Agreement (v. February 25, 2025), as shipped in the
# 580.105.08 .run.
LIC_FILES_CHKSUM = "file://LICENSE;md5=92aa2e2af6aa0bcba1c3fe49da021937"

# NVIDIA-Proprietary is not an SPDX-catalogued license, so map the name to the
# license text NVIDIA ships in the .run (otherwise do_create_spdx cannot find it).
NO_GENERIC_LICENSE[NVIDIA-Proprietary] = "LICENSE"

# genericx86-64 only — a machine-specific prebuilt binary.
COMPATIBLE_MACHINE = "genericx86-64-wendyos"
PACKAGE_ARCH = "${MACHINE_ARCH}"

NVIDIA_ARCH = "x86_64"
NVIDIA_ARCHIVE = "NVIDIA-Linux-${NVIDIA_ARCH}-${PV}"

SRC_URI = "https://download.nvidia.com/XFree86/Linux-${NVIDIA_ARCH}/${PV}/${NVIDIA_ARCHIVE}.run;name=run"
# Checksums of the official download.nvidia.com .run for 580.105.08.
SRC_URI[run.sha256sum] = "d9c6e8188672f3eb74dd04cfa69dd58479fa1d0162c8c28c8d17625763293475"
SRC_URI[run.md5sum] = "c71560d2644e4ae386b83b168d444fb2"

S = "${UNPACKDIR}/${NVIDIA_ARCHIVE}"

# readelf (native) is used to read each lib's SONAME for the symlink chain.
DEPENDS = "binutils-native"

# The .run is a makeself/NVIDIA self-extractor — extract the payload, do not run
# the installer. Extraction must happen at unpack so the LICENSE file exists for
# the checksum check.
do_unpack() {
    rm -rf ${S}
    sh ${DL_DIR}/${NVIDIA_ARCHIVE}.run -x --target ${S}
}

# Runtime userspace of a prebuilt binary driver — silence the QA checks that
# assume our own toolchain built these.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"
EXCLUDE_FROM_SHLIBS = "1"
PRIVATE_LIBS = "*"
SKIP_FILEDEPS:${PN} = "1"
# "arch" is skipped because the GSP firmware blobs are RISC-V ELF images for the
# GPU microprocessor, not host x86-64 code.
INSANE_SKIP:${PN} += "ldflags already-stripped file-rdeps dev-so textrel libdir staticdev arch"

# Compute and management libraries only. The .run also ships the vendor-neutral
# GLVND display stack (libEGL.so.*, libGL.so.*, libGLX*, libnvidia-gl*) plus the
# GTK/Vulkan/video/OptiX libs. Those collide with mesa in the rootfs (libEGL.so.1
# etc.) and are useless for headless GPU compute, so we leave them out.
NVIDIA_COMPUTE_LIBS = " \
    libcuda \
    libcudadebugger \
    libnvidia-ml \
    libnvidia-cfg \
    libnvidia-ptxjitcompiler \
    libnvidia-nvvm \
    libnvidia-gpucomp \
    libnvidia-allocator \
    "

do_install() {
    install -d ${D}${libdir}

    # Install the compute libraries present in this driver release.
    for name in ${NVIDIA_COMPUTE_LIBS}; do
        for lib in ${S}/${name}.so.${PV}; do
            [ -e "$lib" ] || continue
            install -m 0644 "$lib" ${D}${libdir}/
        done
    done

    # Recreate the SONAME link (e.g. libcuda.so.1) and the dev link
    # (libcuda.so) from each lib's own SONAME — version/lib agnostic.
    for lib in ${D}${libdir}/*.so.${PV}; do
        [ -e "$lib" ] || continue
        base=$(basename "$lib")
        soname=$(readelf -d "$lib" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')
        if [ -n "$soname" ] && [ "$soname" != "$base" ]; then
            ln -sf "$base" ${D}${libdir}/"$soname"
        fi
        dev=$(echo "$base" | sed 's/\.so\..*/.so/')
        ln -sf "${soname:-$base}" ${D}${libdir}/"$dev"
    done

    # Management + compute binaries.
    install -d ${D}${bindir}
    for b in nvidia-smi nvidia-debugdump nvidia-cuda-mps-control nvidia-cuda-mps-server nvidia-persistenced; do
        [ -f ${S}/$b ] && install -m 0755 ${S}/$b ${D}${bindir}/$b
    done
    # nvidia-modprobe is setuid root — it creates the /dev/nvidia* nodes and
    # loads the modules on first use.
    [ -f ${S}/nvidia-modprobe ] && install -m 4755 ${S}/nvidia-modprobe ${D}${bindir}/nvidia-modprobe

    # GSP firmware — mandatory for the Blackwell open modules to initialize the
    # GPU. The open modules look under /lib/firmware/nvidia/${PV}/.
    install -d ${D}${nonarch_base_libdir}/firmware/nvidia/${PV}
    for fw in ${S}/firmware/*.bin; do
        [ -e "$fw" ] || continue
        install -m 0644 "$fw" ${D}${nonarch_base_libdir}/firmware/nvidia/${PV}/
    done
}

FILES:${PN} += " \
    ${libdir}/*.so \
    ${libdir}/*.so.* \
    ${bindir}/* \
    ${nonarch_base_libdir}/firmware/nvidia \
    "

# Useless without the matching kernel modules.
RDEPENDS:${PN} = "kernel-module-nvidia"

