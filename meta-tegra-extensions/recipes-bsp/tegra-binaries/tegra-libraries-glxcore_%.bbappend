# NVIDIA's Vulkan ICD loads libGLX_nvidia.so.0 even for headless workloads.
# WendyOS does not run X11, but containers still need this driver entry point.
REQUIRED_DISTRO_FEATURES:remove = "x11"
