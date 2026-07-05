SUMMARY = "Enroll WendyOS GRUB2 into the UEFI BootOrder on first boot (Jetson)"
DESCRIPTION = "One-shot boot service that stages grubaa64.efi + grub.cfg + \
grubenv onto the (upstream-populated) ESP and registers a UEFI Boot#### for \
grubaa64.efi as the first BootOrder entry — keeping L4TLauncher enrolled as a \
lower-priority fallback so the device can never be left unbootable. Idempotent \
(marker on /data) and fails safe: any error leaves the existing BootOrder \
untouched. Only built into the image on the GRUB A/B boot path \
(WENDYOS_TEGRA_GRUB_AB = 1)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://wendyos-grub-firstboot.sh \
    file://wendyos-grub-firstboot.service \
    "
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "(tegra)"

inherit systemd

SYSTEMD_SERVICE:${PN} = "wendyos-grub-firstboot.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-grub-firstboot.sh \
        ${D}${sbindir}/wendyos-grub-firstboot

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-grub-firstboot.service \
        ${D}${systemd_system_unitdir}/
}

# efibootmgr registers the Boot#### / reorders BootOrder; the staged GRUB payload
# ships in wendyos-grub. efivarfs is in-kernel.
RDEPENDS:${PN} = "systemd efibootmgr wendyos-grub"

FILES:${PN} += " \
    ${sbindir}/wendyos-grub-firstboot \
    ${systemd_system_unitdir}/wendyos-grub-firstboot.service \
    "
