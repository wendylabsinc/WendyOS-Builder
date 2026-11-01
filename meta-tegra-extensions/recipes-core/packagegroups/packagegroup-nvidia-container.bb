SUMMARY = "NVIDIA Container Support Packages"
DESCRIPTION = "Ensures all NVIDIA libraries and tools referenced in l4t.csv are installed"

PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

# This package group is designed for the L4T, CUDA, cuDNN and TensorRT
# versions that meta-tegra itself provides. We pin none of them.

# The libraries that l4t.csv mounts into containers must exist on the device.
# The packages below provide them:
#
# - CUDA: cuda-cudart, cuda-nvrtc, cuda-nvtx, cuda-cupti, libcufile and
#   cuda-libraries (the math libraries, listed below RDEPENDS). cuda-toolkit
#   adds the compiler and the development files.
# - cuDNN, cuSPARSELt and TensorRT: cudnn, cusparselt, tensorrt and
#   tensorrt-plugins.
# - Tegra driver libraries: the tegra-libraries-* packages (CUDA driver,
#   multimedia, video decoding, camera, NvSci, EGL and OpenGL ES).
# - Container runtime: nvidia-container-toolkit (nvidia-ctk, which writes the
#   GPU description that containers use), libnvidia-container,
#   nvidia-container-config (installs l4t.csv) and nerdctl.
#
# Note: cuDSS (direct sparse linear solver) is NOT included in the base OS.
# Install it in containers via pip when needed, matching the container's CUDA
# major version:
#   pip install nvidia-cudss-cu13   (CUDA 13, as on the device)
#   pip install nvidia-cudss-cu12   (CUDA 12)

# Core packages required for l4t.csv container support (always included)
# - tensorrt-trtexec-prebuilt: trtexec is TensorRT's test tool, and TensorRT
#   stays on the device.
# - tegra-libraries-multimedia-ds: provides libnvdsbufferpool. meta-tegra's
#   drivers.csv mounts it from /usr/lib into containers, so DeepStream apps in
#   containers need it on the device.
RDEPENDS:${PN} = " \
    nvidia-container-config \
    nvidia-container-toolkit \
    libnvidia-container \
    nerdctl \
    cuda-toolkit \
    cuda-cudart \
    cuda-libraries \
    cuda-nvrtc \
    cuda-nvtx \
    cuda-cupti \
    tegra-libraries-core \
    tegra-libraries-cuda \
    tegra-libraries-multimedia \
    tegra-libraries-multimedia-utils \
    tegra-libraries-multimedia-v4l \
    tegra-libraries-nvsci \
    tegra-libraries-camera \
    tegra-libraries-eglcore \
    tegra-libraries-glescore \
    cudnn \
    cusparselt \
    tensorrt \
    tensorrt-plugins \
    libcufile \
    tensorrt-trtexec-prebuilt \
    tegra-libraries-multimedia-ds \
    "

# Note: cuda-libraries is an empty package that pulls in cuda-cudart,
# cuda-nvrtc, libcublas, libcufft, libcufile, libcurand, libcusolver,
# libcusparse, libnpp, libnvfatbin, libnvjitlink and libnvjpeg.
#
# cuSPARSELt (lightweight sparse operations) is packaged separately by the
# cusparselt recipe in meta-tegra-extensions/recipes-devtools/cusparselt/

# Note: TensorRT now included since opengl is enabled in distro config

# Optional packages for additional functionality
# Uncomment as needed:
#
# Additional CUDA tools:
# RDEPENDS:${PN} += "cuda-samples"           # CUDA sample programs
# RDEPENDS:${PN} += "cuda-gdb"               # CUDA debugger
# RDEPENDS:${PN} += "tegra-cuda-utils"       # Tegra CUDA utilities
#
# TensorRT extras:
# RDEPENDS:${PN} += "tensorrt-trtexec"       # TensorRT execution utility
# RDEPENDS:${PN} += "tensorrt-samples"       # TensorRT samples
#
# cuDNN samples:
# RDEPENDS:${PN} += "cudnn-samples"          # cuDNN sample programs
#
# Python support:
# RDEPENDS:${PN} += "python3-tensorrt"       # Python TensorRT bindings
# RDEPENDS:${PN} += "python3-pycuda"         # Python CUDA bindings
#
# Note: Most CUDA math libraries (cublas, cusparse, cusolver, etc.) are included
# in cuda-libraries and cuda-toolkit packages
