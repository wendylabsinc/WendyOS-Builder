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

# Master gate for the TPM 2.0 stack.
# Opt-in, default on for x86. Set to "0" to build the pre-TPM image.
# Gates the kernel TPM drivers (x86-tpm.cfg), systemd's tpm2 +
# cryptsetup support, and the TPM/LUKS userspace, and (later) the first-boot enroll
# service. Defined here so it stays x86-only for now
# (it can move to common config if other boards adopt TPM).
WENDYOS_ENABLE_TPM ?= "0"

# meta-tpm gates some of its bbappends and PREFERRED_VERSION settings on the tpm2
# DISTRO feature. Without it bitbake warns and those settings silently do not apply.
# Add it when the TPM stack is enabled. Gated + defined in this x86-only include, so
# other boards and a TPM-off x86 build are untouched.
DISTRO_FEATURES:append = "${@' tpm2' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"
