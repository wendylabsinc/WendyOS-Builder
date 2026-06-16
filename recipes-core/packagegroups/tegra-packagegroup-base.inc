# Tegra-specific packagegroup-wendyos-base configuration
# This file is included when building for Tegra machines

# Tegra-specific tools and hardware support.
# tegra-flash-reboot ships ONLY on scarthgap meta-tegra (Orin / tegra234 /
# JP6). Neither Thor (tegra264) nor the JP7.2/blacksail tree has the recipe
# (blacksail's tegra-flash-init does not RDEPEND on it), so gate on BOTH the
# SoC and the scarthgap layer tree — a bare tegra234 check would wrongly pull
# it on blacksail Orin ("Nothing PROVIDES tegra-flash-reboot").
RDEPENDS:${PN}:append = " \
    efibootmgr \
    ${@'tegra-flash-reboot' if ('tegra234' in d.getVar('MACHINEOVERRIDES').split(':') and (d.getVar('WENDYOS_LAYER_TREE') or '') == 'scarthgap') else ''} \
    tegra-tools-tegrastats \
    "

# OP-TEE normal-world userspace:
# tee-supplicant (shipped by optee-client) is the Linux daemon that services
# secure-world RPC: it backs REE-FS secure storage by writing TEE-encrypted
# blobs to /var/lib/tee, loads dynamic TAs, and forwards RPMB. 
# Without it, any TA that uses persistent objects (PKCS#11 tokens, device
# keys) has no backing store.
# Tegra-only (this .inc is Tegra-only), QEMU/RPi have no OP-TEE.
# Requires the OP-TEE OS loaded by the bootloader + the tee kernel
# driver to be functional at runtime (both handled by the Tegra boot assembly).
RDEPENDS:${PN}:append = " optee-client"

# OP-TEE filesystem TAs (the /lib/optee_armtz set, including the PKCS#11 TA
# enabled via optee-os_%.bbappend). tee-supplicant loads these from REE-FS on
# demand, so the runtime package must actually ship them to the device.
# This is a production capability (secure key storage), not debug-only.
RDEPENDS:${PN}:append = " optee-os"

# OP-TEE secure-storage persistence:
# bind-mount /var/lib/tee -> /data/tee so PKCS#11 tokens / device keys
# survive Mender A/B OTA (the rootfs copy of /var/lib/tee is wiped on
# every A/B switch). 
# Gated on OP-TEE, which is present on every Tegra machine.
# QEMU/RPi have no OP-TEE.
# The mount itself self-gates on /data via RequiresMountsFor=/data, so it is
# inert on any Tegra config that lacks a /data partition.
RDEPENDS:${PN}:append = " systemd-mount-tee"
