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
