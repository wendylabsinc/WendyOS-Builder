SUMMARY = "WendyOS NVIDIA dGPU driver and container-compute stack (x86)"
DESCRIPTION = "Bundles the NVIDIA open kernel modules, the matching proprietary \
userspace (CUDA driver, NVML, nvidia-smi, GSP firmware), the container toolkit \
(nvidia-ctk) and the CDI generation helper. Together they enable GPU compute in \
containers (nerdctl --gpus all) on x86 PCs with an NVIDIA dGPU such as the RTX 5050. \
This is the single package both delivery paths use: baked into the image for \
validation, or published to the driver feed for shipping."
LICENSE = "MIT"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

COMPATIBLE_MACHINE = "(genericx86-64-wendyos)"

# nvidia-open-kmod is the recipe's base package (distinct from the auto-split
# kernel-module-* packages). It carries /etc/modprobe.d/nvidia.conf, which
# blacklists nouveau. Without it, nouveau binds the GPU first and the nvidia
# module load faults the kernel at boot.
RDEPENDS:${PN} = " \
    nvidia-open-kmod \
    kernel-module-nvidia \
    kernel-module-nvidia-uvm \
    nvidia-userspace \
    nvidia-container-toolkit \
    wendyos-gpu-cdi \
    "
