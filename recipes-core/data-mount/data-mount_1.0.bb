SUMMARY = "The data.mount unit for the boards whose /data is not in fstab"
DESCRIPTION = "Ships one file: the data.mount unit that mounts the persistent \
/data partition. Tegra and Qualcomm need it because, unlike the x86, VM and RPi \
images, they carry no /data line in fstab for systemd-fstab-generator to build a \
mount from; those three images remove this package again. Preparing the \
partition is not this recipe's job any more: the first-boot format and the grow \
it used to do are wendyos-data.service in the data-device recipe, which ships on \
every board."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://data.mount"

S = "${UNPACKDIR}"

inherit systemd

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/data.mount ${D}${systemd_system_unitdir}/
}

FILES:${PN} = "${systemd_system_unitdir}/data.mount"

SYSTEMD_SERVICE:${PN} = "data.mount"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# No RDEPENDS, on purpose. The bash, coreutils, util-linux, parted, e2fsprogs
# and gptfdisk this recipe used to pull in belonged to the first-boot script it
# no longer ships; data-device declares them for wendyos-data.service instead. A
# unit file needs nothing at runtime.
