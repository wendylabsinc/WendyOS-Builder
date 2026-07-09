# x86 ships its own copies of the two identity generator units (same filenames),
# which win over the base wendyos-identity recipe's via this prepended path. The
# base (Tegra/RPi) units order against wendyos-etc-binds / the /data bind; x86
# has no /data (WENDYOS_OTA=none), so its variants simply drop that dependency
# and write identity straight to the persistent rootfs. This layer is only in
# BBLAYERS for x86 builds, so the override never reaches other boards.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

