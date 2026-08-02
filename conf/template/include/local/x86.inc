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

# LUKS2 encryption of /data, sealed to the TPM. Default ON.
# Set WENDYOS_DATA_ENCRYPTED = "0" in local.conf for a plain-ext4 /data.
# Gates the TPM/LUKS userspace, the first-boot enroll service (data-crypt),
# systemd's cryptsetup support, and the fstab/mount rewiring. Jetson has the
# same knob in local/tegra-t264.inc / tegra-t234.inc.
WENDYOS_DATA_ENCRYPTED ?= "1"

# Master gate for the TPM 2.0 stack itself: the kernel TPM drivers
# (x86-tpm.cfg), systemd's tpm2 support, and the tpm2 DISTRO feature below.
# Encrypting /data needs a TPM at runtime, so it turns this on. Nothing turns
# encryption on implicitly. Set = "1" in local.conf for a TPM with nothing
# consuming it. Setting = "0" while WENDYOS_DATA_ENCRYPTED = "1" is a hard
# error (wendyos-image.bb).
WENDYOS_ENABLE_TPM ?= "${@'1' if d.getVar('WENDYOS_DATA_ENCRYPTED') == '1' else '0'}"

# meta-tpm gates some of its bbappends and PREFERRED_VERSION settings on the tpm2
# DISTRO feature. Without it bitbake warns and those settings silently do not apply.
# Add it when the TPM stack is enabled. Gated + defined in this x86-only include, so
# other boards and a TPM-off x86 build are untouched.
DISTRO_FEATURES:append = "${@' tpm2' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"

# meta-tpm warns on every parse when tpm2 is absent from DISTRO_FEATURES
# (sanity-meta-tpm.bbclass). We layer it unconditionally because BBLAYERS cannot
# read this gate, so on a TPM-off build that warning is expected noise rather
# than a problem. Use the layer's own opt-out, but only while the stack is off:
# with it on, the check still catches a DISTRO_FEATURES append that failed to
# apply.
SKIP_META_TPM_SANITY_CHECK = "${@'1' if d.getVar('WENDYOS_ENABLE_TPM') != '1' else '0'}"

