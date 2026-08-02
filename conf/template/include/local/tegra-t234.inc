# Tegra T234 (Orin / Orin Nano): wendyos-update OTA on JetPack 7.2 /
# L4T R39.2.0 (blacksail). Symmetric with tegra-t264.inc (Thor).
#
# This is the JP7.2 fleet-unification path: r39.2.0 is the first JetPack 7
# line to support the Orin family alongside Thor, so all three Jetson boards
# can share one Yocto series (blacksail) and one OTA stack (wendyos-update).

# wendyos-update OTA (also the wendyos.conf default; kept explicit here).
# Pulls in the client + data-setup + the .wendy artifact
# (conf/distro/include/wendyos-update.inc) and implies the persistent /data
# partition — allocated empty at flash time and formatted/grown on first
# boot by wendyos-data-setup. See tegra_partition_config.bbclass.
WENDYOS_OTA = "wendy"

# Fixed A/B rootfs slot size: 12 GiB per slot on every build, so an OTA rootfs
# image always fits the on-device APP/APP_b partition (set at flash time, never
# re-created). ROOTFSPART_SIZE_DEFAULT is the single-slot value; the redundant
# A/B layout (USE_REDUNDANT_FLASH_LAYOUT=1, set in the machine conf) halves it,
# so 24 GiB -> 12 GiB per slot. image_types_tegra.bbclass uses the resulting
# ROOTFSPART_SIZE as APPSIZE in the generated flash layout. Strong '=' here
# (parsed via local.conf, before the upstream orin-nano.inc/agx-orin.inc '?=')
# wins. 24 GiB = 24 * 1024^3 bytes.
ROOTFSPART_SIZE_DEFAULT = "25769803776"

# The wendy rootfs is pinned to a fixed 12 GiB (wendyos-rootfs-size.inc), which
# equals this slot, so image == slot == OTA payload. Keep the ext4 a 128 MiB
# (32768 4K-block) multiple so blocks_per_group stays 32768: EDK2 Ext4Pkg
# (L4TLauncher's ext4 reader) rejects blocks_per_group != 8*blocksize with
# EFI_UNSUPPORTED and the board boot-loops. 12 GiB is already a 128 MiB
# multiple, so this is a no-op guard today. Scoped :pn-wendyos-image —
# machine-wide would round the ESP (tegra-espimage) past its 64 MiB max and
# fail the build; IMAGE_ROOTFS_ALIGNMENT also feeds TEGRA_BLBLOCKSIZE, pinned
# to its current 4 KiB so mksparse / the flash helper are unchanged.
IMAGE_ROOTFS_ALIGNMENT:pn-wendyos-image = "131072"
TEGRA_BLBLOCKSIZE:pn-wendyos-image = "4096"

# OTA uses the UEFI capsule-on-disk bootloader update on t234.
WENDYOS_UPDATE_BOOTLOADER = "0"

# Persistent journal logs left at the smart default (tracks WENDYOS_OTA):
# WENDYOS_OTA="wendy" -> persistent on /data.

# UEFI/EFI debug build mode:
#   "0" - RELEASE (minimal UART output, production default)
#   "1" - DEBUG (verbose boot/capsule debug output)
WENDYOS_EFI_DEBUG = "0"

# DeepStream 8.0 (JetPack 7.2 / CUDA 13) — ENABLED. tegra-image.inc resolves
# WENDYOS_DEEPSTREAM=1 to the deepstream-8.0 package on blacksail, provided by
# our vendored recipe in meta-tegra-extensions-jp7 (DS8 is not yet on the
# meta-tegra-community wip-l4t-r39.2.0 branch — see scripts/check-jp7.2-upstream.sh
# for when to drop the vendored recipe). COMPATIBLE_MACHINE=(tegra), so the same
# recipe serves Orin (t234) and Thor (t264).
WENDYOS_DEEPSTREAM = "1"

# LUKS2 encryption of /data, sealed to the fTPM. Default ON.
# Set WENDYOS_DATA_ENCRYPTED = "0" in local.conf for a plain-ext4 /data.
WENDYOS_DATA_ENCRYPTED ?= "1"

# Master gate for the TPM 2.0 stack itself (fTPM over OP-TEE). Encrypting
# /data needs a TPM at runtime, so it turns this on. Nothing turns encryption
# on implicitly. Set = "1" in local.conf for a TPM with nothing consuming it.
# Setting = "0" while WENDYOS_DATA_ENCRYPTED = "1" is a hard error
# (wendyos-image.bb).
# t234 needs no DT overlay, unlike Thor: NVIDIA's tegra-optee.dtbo (applied to
# the kernel DTB on every t234 board via TEGRA_PLUGIN_MANAGER_OVERLAYS) already
# carries firmware/ftpm status="disabled", and the UEFI kernel-DTB fixup
# (EnableFtpmNode, edk2-nvidia DxeDtPlatformDtbKernelLoaderLib) flips it to
# "okay" exactly when the fTPM TA in OP-TEE answers — self-arming. meta-tpm
# gates bbappends/PREFERRED_VERSION on the tpm2 DISTRO feature, so add it only
# when the stack is on.
WENDYOS_ENABLE_TPM ?= "${@'1' if d.getVar('WENDYOS_DATA_ENCRYPTED') == '1' else '0'}"
DISTRO_FEATURES:append = "${@' tpm2' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"

# meta-tpm warns on every parse when tpm2 is absent from DISTRO_FEATURES
# (sanity-meta-tpm.bbclass). We layer it unconditionally because BBLAYERS cannot
# read this gate, so on a TPM-off build that warning is expected noise rather
# than a problem. Use the layer's own opt-out, but only while the stack is off:
# with it on, the check still catches a DISTRO_FEATURES append that failed to
# apply.
SKIP_META_TPM_SANITY_CHECK = "${@'1' if d.getVar('WENDYOS_ENABLE_TPM') != '1' else '0'}"

# Build the fTPM TA into OP-TEE (upstream optee-l4t.inc defaults this on only
# for tegra264). Gated on the TPM knob so a TPM-off Orin build keeps today's
# bit-identical firmware — and because the UEFI fixup above enables the DT node
# whenever the TA exists, an ungated "1" would surface /dev/tpmrm0 without the
# sequencing userspace (no modprobe blacklist -> early load -> RAM-only fTPM).
OPTEE_ENABLE_FTPM = "${@'1' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else '0'}"

# PCR policy for the TPM keyslot: empty = SRK-only (no PCR binding), until
# secure boot lands (then bind an OTA-stable PCR). The data-crypt recipe
# defaults this to "7" for x86 (Secure Boot state); override to SRK-only.
WENDYOS_TPM_PCRS = ""

