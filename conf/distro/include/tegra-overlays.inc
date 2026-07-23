
# WendyOS Tegra boot-control DT overlays -- the single definition of what gets
# merged into the boot-chain firmware DTB.
#
# This file MUST be required by EVERY recipe that packages boot-chain firmware
# from TEGRA_BOOTCONTROL_OVERLAYS, currently:
#   - wendyos-image (via conf/distro/include/tegra-image.inc): the flash package
#   - tegra-uefi-capsules (via its bbappend in meta-tegra-extensions): the UEFI
#     capsule payload
# If one of them sees a different list, flashed firmware and capsule-updated
# firmware diverge: an overlay-less capsule erased the fTPM DT node from
# boot-chain B and left the encrypted /data locked (Thor). The other
# readers of the variable (edk2-firmware-tegra, tegra-uefi-prebuilt) only loop
# to deploy files they built themselves and skip unknown names, so they do not
# need this file. Require it exactly once per recipe.

# UEFI boot-priority overlay (NVMe first on NVMe machines).
TEGRA_BOOTCONTROL_OVERLAYS:append = " boot-priority.dtbo"

# fTPM device-tree overlay (opt-in via WENDYOS_ENABLE_TPM). NVIDIA ships the
# firmware/ftpm node status="disabled"; tegra-ftpm-overlay re-emits it "okay" so
# tpm_ftpm_tee binds and /dev/tpmrm0 appears. Only tegra264 (Thor) is validated;
# Orin needs its own overlay + OPTEE_ENABLE_FTPM:tegra234="1" (an OP-TEE rebuild)
# -- map WENDYOS_FTPM_DTBO:tegra234 once validated.
WENDYOS_FTPM_DTBO = ""
WENDYOS_FTPM_DTBO:tegra264 = "tegra264-ftpm.dtbo"
TEGRA_BOOTCONTROL_OVERLAYS:append = "${@(' ' + d.getVar('WENDYOS_FTPM_DTBO')) if d.getVar('WENDYOS_ENABLE_TPM') == '1' and d.getVar('WENDYOS_FTPM_DTBO') else ''}"

