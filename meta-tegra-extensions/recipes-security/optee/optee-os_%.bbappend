# Enable the GlobalPlatform PKCS#11 Trusted Application in the OP-TEE build.
#
# CFG_PKCS11_TA=y compiles the Cryptoki token TA (ta/pkcs11/*.ta) so the
# device can store keys (device-tls, UEFI PK/KEK) in OP-TEE secure storage
# instead of in cleartext on the rootfs.
#
# The base recipe's do_install harvests every built *.ta from ${B}/ta into
# /lib/optee_armtz (FILES:${PN}), so enabling this config is enough — no extra
# install rule is needed here. Delivery to the device happens via the optee-os
# runtime package (see recipes-core/packagegroups/tegra-packagegroup-base.inc);
# tee-supplicant loads the TA from REE-FS on demand at runtime.
#
# Version-agnostic _%.bbappend so it survives the future r38/wrynose meta-tegra
# bump (optee-os recipe version changes).
EXTRA_OEMAKE += "CFG_PKCS11_TA=y"
