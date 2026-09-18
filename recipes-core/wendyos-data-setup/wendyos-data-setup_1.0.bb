SUMMARY = "First-boot /data partition setup for the wendyos-update OTA stack"
DESCRIPTION = "Formats and grows the persistent /data partition on first \
boot, and mounts it at /data. Provides /data partition growth and the \
fstab entry for boards using the wendyos-update OTA client (WENDYOS_OTA = wendy). \
The partition is carved allocated-empty by tegra_partition_config.bbclass; \
this initialises it. Idempotency keys on the on-disk ext4 filesystem, not a \
per-rootfs stamp, so an A/B rootfs swap can never wipe /data."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://wendyos-data-init.sh \
    file://wendyos-data-init.service \
    file://data.mount \
    file://wants-data-consumers.conf \
    file://data-device-timeout.conf \
"

S = "${UNPACKDIR}"

inherit systemd

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-data-init.sh ${D}${sbindir}/wendyos-data-init.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-data-init.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/data.mount ${D}${systemd_system_unitdir}/

    # Pull the /data consumers in whenever data.mount is (re)started, not
    # just on the boot that first mounted it (WDY-3127). Also effective for
    # the LUKS variant: the bbappend installs data-luks.mount AS data.mount,
    # so this drop-in applies under either unit name.
    install -d ${D}${systemd_system_unitdir}/data.mount.d
    install -m 0644 ${UNPACKDIR}/wants-data-consumers.conf ${D}${systemd_system_unitdir}/data.mount.d/wants-data-consumers.conf

    # x-systemd.device-timeout= in a .mount unit's Options= is silently
    # ignored -- systemd only honours it in /etc/fstab, where
    # systemd-fstab-generator translates it into exactly this kind of
    # drop-in on the DEVICE unit. Ship that drop-in directly on the
    # by-partlabel device unit (WDY-3127). The directory name below must
    # keep the literal backslash from the device unit's escaped name
    # (dev-disk-by\x2dpartlabel-data.device, same name wendyos-data-init.service
    # already Wants=/After=s) -- quoted so the shell does not touch it.
    install -d "${D}${systemd_system_unitdir}/dev-disk-by\x2dpartlabel-data.device.d"
    install -m 0644 ${UNPACKDIR}/data-device-timeout.conf "${D}${systemd_system_unitdir}/dev-disk-by\x2dpartlabel-data.device.d/50-wendyos-device-timeout.conf"
}

FILES:${PN} += " \
    ${sbindir}/wendyos-data-init.sh \
    ${systemd_system_unitdir}/wendyos-data-init.service \
    ${systemd_system_unitdir}/data.mount \
    ${systemd_system_unitdir}/data.mount.d/wants-data-consumers.conf \
    ${systemd_system_unitdir}/dev-disk-by\x2dpartlabel-data.device.d/50-wendyos-device-timeout.conf \
"

# data.mount is enabled via its [Install] WantedBy; the init service is
# pulled in as a dependency of data.mount.
SYSTEMD_SERVICE:${PN} = "wendyos-data-init.service data.mount"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# e2fsprogs-dumpe2fs is what makes the "already initialised?" probe work: if
# dumpe2fs is absent the guard cannot read the superblock, and the script falls
# through to mkfs.ext4 -F, wiping /data on EVERY boot.
RDEPENDS:${PN} = "bash coreutils util-linux parted e2fsprogs-mke2fs e2fsprogs-dumpe2fs gptfdisk"
