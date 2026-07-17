# Generic x86_64 PC defaults.
#
# MVP target: commodity UEFI/BIOS PCs such as Intel NUC-class systems,
# AMD mini PCs, and desktop PCs with optional NVIDIA dGPUs.

# Commodity PCs do not expose a USB peripheral controller for WendyOS gadget
# networking. Discovery should happen on LAN interfaces.
WENDYOS_USB_GADGET = "0"
WENDYOS_MDNS_INTERFACES = ""

# Experimental helper only. The service no-ops unless an NVIDIA driver and
# nvidia-ctk are present on the image.
WENDYOS_NVIDIA_DGPU ?= "1"

# generic-x86-64 is the only board that cold-builds the LLVM/Clang/mesa graphics
# stack (PACKAGECONFIG:append:x86-64), and the self-hosted builder runs each job
# in a hard 16 GiB memory cgroup. The build Makefile narrows the bitbake env
# passthrough, dropping BB_NUMBER_THREADS and PARALLEL_MAKE, so both otherwise
# default to the box nproc (96) — 8 recipes x 96 compilers blows past 16 GiB on
# the cold graphics compile. Pin both low in-conf (env-independent). Validated:
# full cold image build peaks ~13 GiB anon, no OOM.
BB_NUMBER_THREADS = "8"
PARALLEL_MAKE = "-j 8"
