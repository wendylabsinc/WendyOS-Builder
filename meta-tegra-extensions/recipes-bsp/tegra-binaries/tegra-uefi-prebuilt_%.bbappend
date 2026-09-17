# Deploy the FMP system image type GUID alongside the prebuilt UEFI firmware.
#
# tegra-uefi-capsules reads the GUID it embeds in a capsule from
# ${DEPLOY_DIR_IMAGE}/${TEGRA_FLASHVAR_UEFI_IMAGE}.fmp-image-type-id and fails
# do_compile with "Missing FMP system image type GUID file" when it is absent.
# Upstream added that file in meta-tegra 76d8f333 (2026-07-25), replacing the
# GUIDs the capsule recipe used to hardcode per SoC, because the value differs
# per EDK2 configuration (minimal / general / simple_*) and must match the
# firmware's ESRT for a capsule to be accepted.
#
# Only edk2-firmware-tegra was taught to deploy it -- it writes the GUID that
# its own EDK2 build resolved. tegra-uefi-prebuilt was not, so pairing NVIDIA's
# prebuilt firmware with capsule updates now breaks. We use the prebuilt
# firmware on every Jetson (see the machine confs), so restore the file here.
#
# For prebuilt firmware the GUID is a fixed property of the binary NVIDIA
# ships, not something our build chooses, so hardcoding is correct here in a
# way it no longer is for a source build. The values are upstream's own, taken
# from tegra-uefi-capsules_39.2.0.bb before 76d8f333 removed them.
#
# CONFIRMED ON DEVICE, both SoCs, on the prebuilt r39.2 firmware. Each reports
# its value from /sys/firmware/efi/esrt/entries/entry0/fw_class:
#   tegra264 (AGX Thor)  -> 3c834404-d2d7-4912-8c1c-6e850b5f2824  (2026-08-05,
#                           and a capsule built with it applied end to end:
#                           ESRT last_attempt_status 0, boot chain switched)
#   tegra234 (AGX Orin)  -> bf0d4599-20d4-414e-b2c5-3595b1cda402  (2026-08-05,
#                           GUID match confirmed; capsule apply not yet run)
# Re-check both after any BSP bump: a wrong GUID is NOT a build error, it
# surfaces as the firmware rejecting the capsule at update time.
TEGRA_UEFI_SYSTEM_IMAGE_TYPE_GUID:tegra234 = "bf0d4599-20d4-414e-b2c5-3595b1cda402"
TEGRA_UEFI_SYSTEM_IMAGE_TYPE_GUID:tegra264 = "3c834404-d2d7-4912-8c1c-6e850b5f2824"

do_deploy:append() {
    if [ -n "${TEGRA_UEFI_SYSTEM_IMAGE_TYPE_GUID}" ]; then
        echo "${TEGRA_UEFI_SYSTEM_IMAGE_TYPE_GUID}" \
            > ${DEPLOYDIR}/${TEGRA_FLASHVAR_UEFI_IMAGE}.fmp-image-type-id
    fi
}
