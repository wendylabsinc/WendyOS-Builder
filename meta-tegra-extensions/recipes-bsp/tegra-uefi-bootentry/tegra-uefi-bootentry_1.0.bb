SUMMARY = "Register a UEFI boot entry for the ESP on raw-installed Jetsons"
DESCRIPTION = "One-shot boot service that registers a proper HD(GPT) UEFI boot \
entry for the EFI System Partition when a valid one is missing — the state left \
by flashing a disk image directly to storage (raw `wendy os install` / \
doexternal.sh --sdcard) instead of via tegraflash, which assigns fresh random \
partition GUIDs and never updates the UEFI varstore. Without a registered boot \
entry the device boots via the removable-media fallback, and NVIDIA's UEFI \
capsule-on-disk flow (bootloader OTA) only runs for a registered boot device — \
so capsule OTAs silently no-op and roll back. Idempotent and self-healing: it \
acts only when the entry is absent, needs no reboot, and re-registers after each \
raw install (new PARTUUID)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://tegra-uefi-bootentry.sh \
    file://tegra-uefi-bootentry.service \
    "

S = "${UNPACKDIR}"

inherit systemd allarch

SYSTEMD_SERVICE:${PN} = "tegra-uefi-bootentry.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/tegra-uefi-bootentry.sh \
        ${D}${sbindir}/tegra-uefi-bootentry

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/tegra-uefi-bootentry.service \
        ${D}${systemd_system_unitdir}/
}

# efibootmgr does the registration; util-linux-lsblk resolves the ESP's parent
# disk / partition number / PARTUUID. The script also guards on efibootmgr's
# presence and skips cleanly if absent.
RDEPENDS:${PN} = "systemd efibootmgr util-linux-lsblk"

FILES:${PN} += " \
    ${sbindir}/tegra-uefi-bootentry \
    ${systemd_system_unitdir}/tegra-uefi-bootentry.service \
    "

