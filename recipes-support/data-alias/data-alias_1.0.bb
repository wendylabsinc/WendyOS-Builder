SUMMARY = "Stable /dev/wendyos/data alias for the persistent data device"
DESCRIPTION = "Ships a udev rule that points /dev/wendyos/data at the persistent \
    /data device, whether that is a plain partition or an unlocked LUKS mapper. \
    A .mount unit's What= is a fixed string, so one image can only mount /data \
    both ways if the device path itself varies. The alias provides that, and \
    being a udev symlink it also gets a .device unit the mount can wait on."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-wendyos-data.rules"

# MBR has no partition names, so the GPT rule cannot match on rpi3. Its extra
# rule matches the filesystem label instead, which is weaker, so it ships only
# on the board that needs it. Pinned to :raspberrypi3-64 to mirror the override
# used in rpi-base-files.inc (see the comment there).
SRC_URI:append:raspberrypi3-64 = " file://99-wendyos-data-mbr.rules"

# The package contents differ per machine. Without this the package is shared
# across every board of the same tune, and sstate could hand an rpi4/rpi5 build
# the rpi3 variant, or the other way round.
PACKAGE_ARCH = "${MACHINE_ARCH}"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/99-wendyos-data.rules ${D}${sysconfdir}/udev/rules.d/
}

do_install:append:raspberrypi3-64() {
    install -m 0644 ${UNPACKDIR}/99-wendyos-data-mbr.rules ${D}${sysconfdir}/udev/rules.d/
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/99-wendyos-data.rules"
FILES:${PN}:append:raspberrypi3-64 = " ${sysconfdir}/udev/rules.d/99-wendyos-data-mbr.rules"

RDEPENDS:${PN} = "udev"
