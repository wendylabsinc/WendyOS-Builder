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

# Rootfs-only swaps for now (no UEFI capsule bootloader update). The t234
# capsule path needs its own on-device verification on r39.2 — the ESRT
# entry0 + fw_class GUID must be confirmed (Thor's GUID 3c834404 is
# t264-only) — so it's a later phase mirroring Thor's Step B. Keep off.
WENDYOS_UPDATE_BOOTLOADER = "1"

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
