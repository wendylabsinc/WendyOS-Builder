SUMMARY = "The /data device: what it is, preparing it, and when it is ready to mount"
DESCRIPTION = "Owns the whole life of the /data device up to the mount: naming it, \
    deciding what it is, preparing it, and the ordering around the mount itself. \
    The udev rules give it one name, the /dev/wendyos/data alias, which points at \
    the persistent /data device whether it is a plain partition or an unlocked \
    LUKS mapper. A .mount unit's What= is a fixed string, so one image can only \
    mount /data both ways if the device path itself varies. The alias provides \
    that, and being a udev symlink it also gets a .device unit the mount can wait \
    on. Beside the rules it holds the /data resolver, which decides on every boot \
    whether /data is plain, encrypted or about to be converted, grows the \
    partition to fill the disk and makes sure a plain one carries a filesystem \
    the kernel can mount; the online resize2fs that finishes the grow after the \
    mount; and the data.mount drop-in that keeps the mount out of the way while a \
    conversion runs. All of it ships on every board, so it cannot live in \
    data-crypt, which is installed only when WENDYOS_DATA_ENCRYPTED is 1, nor in \
    wendyos-data-setup, which the x86, RPi and VM images remove."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://99-wendyos-data.rules \
    file://wendyos-data.sh \
    file://wendyos-data.service \
    file://wendyos-data-resize.service \
    file://10-conversion.conf \
    file://10-device.conf \
    "

# MBR has no partition names, so the GPT rule cannot match on rpi3. Its extra
# rule matches the filesystem label instead, which is weaker, so it ships only
# on the board that needs it. The service drop-in beside it is the same story
# one layer up: the device the GPT drop-in waits for cannot exist on MBR, so
# that board waits on the alias instead (see 10-device-mbr.conf). Both pinned
# to :raspberrypi3-64 to mirror the override used in rpi-base-files.inc (see
# the comment there).
SRC_URI:append:raspberrypi3-64 = " \
    file://99-wendyos-data-mbr.rules \
    file://10-device-mbr.conf \
    "

# The package contents differ per machine. Without this the package is shared
# across every board of the same tune, and sstate could hand an rpi4/rpi5 build
# the rpi3 variant, or the other way round.
PACKAGE_ARCH = "${MACHINE_ARCH}"

S = "${UNPACKDIR}"

inherit systemd

# The resolver is pulled in by data.mount through its own [Install] section
# (WantedBy=data.mount), never by a Requires= on the mount, so all this does is
# create that symlink at image build time. The online resize is WantedBy=
# multi-user.target, so each A/B slot wants it in the ordinary way.
SYSTEMD_SERVICE:${PN} = "wendyos-data.service wendyos-data-resize.service"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/99-wendyos-data.rules ${D}${sysconfdir}/udev/rules.d/

    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-data.sh ${D}${sbindir}/wendyos-data.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-data.service ${D}${systemd_system_unitdir}/wendyos-data.service
    install -m 0644 ${UNPACKDIR}/wendyos-data-resize.service ${D}${systemd_system_unitdir}/wendyos-data-resize.service

    install -d ${D}${systemd_system_unitdir}/data.mount.d
    install -m 0644 ${UNPACKDIR}/10-conversion.conf ${D}${systemd_system_unitdir}/data.mount.d/10-conversion.conf

    install -d ${D}${systemd_system_unitdir}/wendyos-data.service.d
    install -m 0644 ${UNPACKDIR}/10-device.conf ${D}${systemd_system_unitdir}/wendyos-data.service.d/10-device.conf
}

do_install:append:raspberrypi3-64() {
    install -m 0644 ${UNPACKDIR}/99-wendyos-data-mbr.rules ${D}${sysconfdir}/udev/rules.d/

    # MBR has no GPT partition name, so the device the GPT drop-in waits for
    # can never appear here and the wait would only stall the boot. Replace it
    # rather than drop it: with no drop-in at all the service has no device
    # wait of any kind and races udev's coldplug, which is the race WDY-1888
    # came out of. Overrides are additive, so "this board gets the other file"
    # has to be written as install, remove, install.
    rm -f ${D}${systemd_system_unitdir}/wendyos-data.service.d/10-device.conf
    install -m 0644 ${UNPACKDIR}/10-device-mbr.conf ${D}${systemd_system_unitdir}/wendyos-data.service.d/10-device-mbr.conf
}

FILES:${PN} = " \
    ${sysconfdir}/udev/rules.d/99-wendyos-data.rules \
    ${sbindir}/wendyos-data.sh \
    ${systemd_system_unitdir}/wendyos-data.service \
    ${systemd_system_unitdir}/wendyos-data-resize.service \
    ${systemd_system_unitdir}/data.mount.d/10-conversion.conf \
    ${systemd_system_unitdir}/wendyos-data.service.d/10-device.conf \
    "
FILES:${PN}:append:raspberrypi3-64 = " \
    ${sysconfdir}/udev/rules.d/99-wendyos-data-mbr.rules \
    ${systemd_system_unitdir}/wendyos-data.service.d/10-device-mbr.conf \
    "

# What the resolver needs on EVERY board. Reading the device: coreutils
# (basename, readlink, cat, head, date, tr, sync), util-linux-blkid (the
# filesystem probe), util-linux-wipefs (erasing a stale or unfinished LUKS
# header, which any board can meet) and udev (udevadm settle).
#
# Preparing it, all of which the resolver now does itself (C57) and none of
# which is optional, because it runs on every board and on every boot:
# gptfdisk for sgdisk -e (relocating the GPT backup header), parted for parted
# and partprobe, e2fsprogs-mke2fs for the mkfs.ext4 that makes a filesystem on
# a partition that carries no signature at all, e2fsprogs-e2fsck for the
# clean-flag fsck before the mount, e2fsprogs-resize2fs for the online resize
# afterwards, and util-linux-blockdev for the device size the stale-superblock
# guard compares the superblock against. coreutils appears in both lists: it
# also provides the `timeout` that bounds each of those tools (C59), and it
# outranks busybox's for the alternative (priority 100 against 50), which is
# what makes timeout's exit 124 the status the script actually sees.
#
# util-linux-sfdisk is the odd one out: it is only ever used to READ the
# partition table -- which label it carries, and whether it has an MBR extended
# container that has to be grown before the logical /data inside it can grow.
# Only raspberrypi3-64 has such a container, but the recipe ships fleet-wide
# and the script is one program on every board, so the dependency does too. The
# `sfdisk -d` dump is also what keeps `sgdisk -e` off an MBR disk, where it
# cannot succeed.
#
# e2fsprogs-dumpe2fs is what makes that guard work at all, and its absence is
# the expensive one: with no dumpe2fs the superblock cannot be read, the guard
# reads that as "does not fit", and the script falls through to mkfs.ext4 -F on
# a perfectly good /data. wendyos-data-setup made it an explicit RDEPENDS for
# exactly this reason.
#
# awk is NOT here, and that is a decision left open rather than one taken: the
# script's one awk reads the MBR extended container out of the `sfdisk -d`
# dump, and declaring it would mean picking busybox over gawk for every board.
# The script checks for it at runtime and warns, naming the consequence, so its
# absence shows up in the journal instead of as a /data that quietly stays
# small.
#
# The crypt stack is deliberately NOT here. cryptsetup, systemd-crypt and
# util-linux-blkdiscard are installed only where WENDYOS_DATA_ENCRYPTED is 1,
# through the per-board image includes, while this recipe ships fleet-wide
# including RPi, which can never encrypt. Depending on them here would drag the
# whole stack onto every board. The resolver looks each one up at runtime and
# reports no_support when they are missing.
RDEPENDS:${PN} = " \
    coreutils \
    e2fsprogs-dumpe2fs \
    e2fsprogs-e2fsck \
    e2fsprogs-mke2fs \
    e2fsprogs-resize2fs \
    gptfdisk \
    parted \
    udev \
    util-linux-blkid \
    util-linux-blockdev \
    util-linux-sfdisk \
    util-linux-wipefs \
    "
