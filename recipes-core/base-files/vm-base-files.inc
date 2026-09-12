# WendyOS VM base-files extensions.
# Included conditionally from base-files_%.bbappend — safe for other machines.
#
# Origin: recipes-core/base-files/x86-base-files.inc, minus the encryption branch:
# the VM defaults to WENDYOS_DATA_ENCRYPTED = "0" (vm-distro.inc) and does not
# layer meta-tpm, so there is no /dev/mapper/data to point at. Re-add that branch
# together with the TPM stack if VM /data encryption is ever turned on.

SRC_URI:append = " \
    file://vm-wendy-fstab \
    "

# The VM uses the wendyos-update A/B layout (two rootfs slots): the stock wic fstab
# update is disabled (WIC_CREATE_EXTRA_ARGS = "--no-fstab-update") because a baked
# "/" entry would be wrong on the other slot. Install our A/B fstab instead — no
# "/" entry (GRUB mounts the slot via root=PARTLABEL), /boot stays mounted so the
# grubenv connector can edit EFI/BOOT/grubenv, and /boot, /config and /data are all
# referenced by LABEL so there is nothing to substitute.
#
# Installed unconditionally for the VM machines: it describes the disk layout, which
# the wks always creates, so it is correct whether WENDYOS_OTA is "wendy" or "none".
do_install:append() {
    install -m 0644 ${UNPACKDIR}/vm-wendy-fstab ${D}${sysconfdir}/fstab
}

