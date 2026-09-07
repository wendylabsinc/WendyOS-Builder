SUMMARY = "WendyOS A/B GRUB config and grubenv for the Dragonwing ESP"
DESCRIPTION = "Installs the A/B trial-boot grub.cfg plus a pre-created GRUB \
environment block into the EFI System Partition tree. Packaged separately from \
wendyos-esp-image so the ESP image stays a plain package composition, matching how \
wendyos-update-config ships its file."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/../../files/grub:"
SRC_URI = "file://grubAB-qcom.cfg"
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "iq-8275-evk-wendyos"

# Machine-scoped, not allarch: the config hardcodes this board's console
# (ttyMSM0) and its slot partition numbers.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Take over oe-core's virtual for the ESP grub.cfg. grub-efi RDEPENDS on
# "virtual-grub-bootconf", not on grub-bootconf directly, precisely so a machine
# can substitute its own config ("Grub might require different configuration file
# for different machines" -- grub-bootconf's own DESCRIPTION). Providing the
# virtual, plus PREFERRED_RPROVIDER_virtual-grub-bootconf in the machine conf,
# keeps grub-bootconf out of the image entirely. Without it both packages ship
# ${EFI_FILES_PATH}/grub.cfg and dnf fails the transaction on a file conflict.
RPROVIDES:${PN} += "virtual-grub-bootconf"

# EFI_FILES_PATH / EFI_BOOT_IMAGE live in oe-core's conf/image-uefi.conf, which is
# NOT globally included -- only systemd-boot.bbclass, grub-efi.bbclass, uki.bbclass
# and barebox.bbclass pull it in. Without this the paths below expand empty and
# grub.cfg lands in the rootfs root. Same require line grub-efi.bbclass uses.
require conf/image-uefi.conf

do_install() {
    install -d ${D}${EFI_FILES_PATH}
    install -m 0644 ${UNPACKDIR}/grubAB-qcom.cfg ${D}${EFI_FILES_PATH}/grub.cfg

    # Pre-create the GRUB environment block. GRUB requires it to be EXACTLY 1024
    # bytes: a 25-byte header line then '#' padding. Shipping it matters -- with no
    # grubenv on a fresh flash, the `save_env bootcount` in grub.cfg silently does
    # nothing, so an armed trial never increments its counter and the automatic
    # rollback never fires. grub-editenv on the device rewrites this in place.
    printf '# GRUB Environment Block\n' > ${WORKDIR}/grubenv
    head -c 999 /dev/zero | tr '\0' '#' >> ${WORKDIR}/grubenv
    actual=$(stat -c %s ${WORKDIR}/grubenv)
    if [ "${actual}" != "1024" ]; then
        bbfatal "wendyos-grub-ab: grubenv is ${actual} bytes, GRUB requires exactly 1024"
    fi
    install -m 0644 ${WORKDIR}/grubenv ${D}${EFI_FILES_PATH}/grubenv
}

FILES:${PN} = "${EFI_FILES_PATH}/grub.cfg ${EFI_FILES_PATH}/grubenv"
