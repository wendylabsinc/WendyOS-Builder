# x86 base-files extensions.
# Included conditionally from base-files_%.bbappend — safe for non-x86 machines.

SRC_URI:append = " \
    file://x86-wendy-fstab \
    "

# x86 uses the wendyos-update A/B layout (two rootfs slots): the stock wic fstab
# update is disabled (WIC_CREATE_EXTRA_ARGS = "--no-fstab-update") because a baked
# "/" entry would be wrong on the other slot. Install our A/B fstab instead — no
# "/" entry (GRUB mounts the slot via root=PARTLABEL in grubAB.cfg), /boot stays
# mounted so the grubenv connector can edit EFI/BOOT/grubenv, and /boot, /config
# and /data are all referenced by LABEL so there is nothing to substitute.
#
# Installed unconditionally for x86 (the generic x86 board is being converted to
# A/B). It does not depend on WENDYOS_OTA, so it is correct both in Phase 1
# (OTA=none, layout only) and Phase 2 (OTA=wendy, agent wired).
do_install:append() {
    install -m 0644 ${UNPACKDIR}/x86-wendy-fstab ${D}${sysconfdir}/fstab

    # With the TPM /data-encryption stack on (WENDYOS_ENABLE_TPM), /data is a LUKS
    # mapper device, not the raw labelled partition -- point the mount at
    # /dev/mapper/data so the plaintext partition is never auto-mounted. crypttab +
    # data-enroll.service (data-crypt recipe) create and unlock it. When TPM is off
    # the stock LABEL=data entry stays. See docs/plans/x86-security.md.
    if [ "${WENDYOS_ENABLE_TPM}" = "1" ]; then
        sed -i 's|^LABEL=data |/dev/mapper/data |' ${D}${sysconfdir}/fstab
    fi
}
