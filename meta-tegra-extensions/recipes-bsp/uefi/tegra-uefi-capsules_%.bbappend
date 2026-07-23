
# The capsule payload is built with tegraflash_populate_package, whose
# copy_dtb_overlays hard-copies every TEGRA_BOOTCONTROL_OVERLAYS entry from
# DEPLOY_DIR_IMAGE. Pull in the WendyOS overlay list (shared verbatim with the
# image flash path via tegra-image.inc) so the capsule carries the same DTB
# content as the flash -- without it, capsule updates shipped boot-chain
# firmware missing the overlays, erasing the fTPM DT node on the updated chain
# and leaving the encrypted /data locked (Thor).
require conf/distro/include/tegra-overlays.inc

# The overlays are deployed by our recipes, so the capsule build must wait for
# them (a missing file fails the hard cp loudly):
#   - boot-priority.dtbo    (tegra-bootcontrol-overlay, all Jetsons)
#   - the fTPM overlay      (tegra-ftpm-overlay, only when WENDYOS_ENABLE_TPM=1
#                            and the SoC has a validated overlay)
do_compile[depends] += "tegra-bootcontrol-overlay:do_deploy"
do_compile[depends] += "${@' tegra-ftpm-overlay:do_deploy' if d.getVar('WENDYOS_ENABLE_TPM') == '1' and d.getVar('WENDYOS_FTPM_DTBO') else ''}"

