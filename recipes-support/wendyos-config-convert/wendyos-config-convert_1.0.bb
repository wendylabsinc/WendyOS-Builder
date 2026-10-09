SUMMARY = "Convert the /config partition from FAT32 to ext4 in place"
DESCRIPTION = "Ships the one-shot service that converts /config from FAT32 to ext4 \
without re-flashing the device, keeping everything on the partition. /config has to \
be FAT32 at flash time, because the host that images the device -- Windows or macOS \
-- writes a provisioning seed onto it before first boot and cannot write ext4. \
Afterwards FAT32 costs two things: it has no journal, so a power cut can tear a write \
that nothing repairs, and it has no ownership or permission bits, so anyone who can \
reach the partition can write the file that arms /data encryption. The conversion \
stages the contents of /config onto /data, unmounts /config, formats it as ext4 with \
the same label, mounts it back and copies the contents in again. The staging copy is \
what makes a power cut survivable, so the service runs after /data is mounted rather \
than in early boot, and before the agent, which reads /config. It refuses outright on \
a device whose /data is encrypted or armed for encryption: the backup lives on /data, \
and reformatting /config there could destroy the material that unlocks the disk \
holding the only copy."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://wendyos-config-convert.sh \
    file://wendyos-config-convert.service \
    "

S = "${UNPACKDIR}"

# No PACKAGE_ARCH override: the package is the same script and the same unit on
# every machine. The per-board differences the conversion meets -- the OP-TEE
# bind mount on Tegra, the shipped config.mount on Qualcomm, the generated one
# everywhere else -- are all decided at runtime by the script, not at build
# time by the recipe.

inherit systemd

SYSTEMD_SERVICE:${PN} = "wendyos-config-convert.service"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-config-convert.sh ${D}${sbindir}/wendyos-config-convert.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-config-convert.service ${D}${systemd_system_unitdir}/wendyos-config-convert.service
}

FILES:${PN} = " \
    ${sbindir}/wendyos-config-convert.sh \
    ${systemd_system_unitdir}/wendyos-config-convert.service \
    "

# Every entry is named by the call site it feeds in wendyos-config-convert.sh,
# because a missing one here is not a build error -- the script simply fails at
# the step that needs it, and after step 6 that step is the format:
#   coreutils          cp, du, df, tail, mkdir, mv, rm, sync, readlink,
#                      basename, printf, tr
#   e2fsprogs-mke2fs   mkfs.ext4, which makes the new filesystem
#   udev               udevadm settle, so /dev/disk/by-label/config names the
#                      new filesystem and not the FAT one it replaced before
#                      the partition is mounted again
#   systemd            systemctl, which is how every mount and the OP-TEE
#                      supplicant are stopped and started. It also brings
#                      util-linux-mount and util-linux-umount, which systemd's
#                      own mount units fork -- this script never calls either
#                      one itself, so it does not list them
#
# util-linux-blkid is NOT here, and that is a decision rather than an omission.
# Every filesystem question this script asks is about a MOUNTED filesystem --
# what /config is mounted from, what type it carries, whether anything else
# still holds the device -- and /proc/mounts answers all three with nothing
# installed. blkid answers a different question, about a device nobody has
# mounted, and this script never has to ask it.
#
# awk is NOT here either, for the reason data-device gives: declaring it would
# mean picking busybox over gawk for every board. The two places that need a
# field out of a line of tool output use the shell's own `set --` instead.
RDEPENDS:${PN} = " \
    coreutils \
    e2fsprogs-mke2fs \
    systemd \
    udev \
    "
