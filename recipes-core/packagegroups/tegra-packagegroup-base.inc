# Tegra-specific packagegroup-wendyos-base configuration
# This file is included when building for Tegra machines

# Tegra-specific tools and hardware support.
# tegra-flash-reboot ships only on scarthgap meta-tegra (Orin / tegra234);
# r38.4.x meta-tegra (Thor / tegra264) has no such recipe, so gate it.
RDEPENDS:${PN}:append = " \
    efibootmgr \
    ${@'tegra-flash-reboot' if 'tegra234' in d.getVar('MACHINEOVERRIDES').split(':') else ''} \
    tegra-tools-tegrastats \
    "

# OP-TEE secure-storage persistence: bind-mount /var/lib/tee -> /data/tee so
# PKCS#11 tokens / device keys survive Mender A/B OTA (the rootfs copy of
# /var/lib/tee is wiped on every A/B switch). Gated on OP-TEE, which is present
# on every Tegra machine (this .inc is Tegra-only); QEMU/RPi have no OP-TEE.
# The mount itself self-gates on /data via RequiresMountsFor=/data, so it is
# inert on any Tegra config that lacks a /data partition.
RDEPENDS:${PN}:append = " systemd-mount-tee"
