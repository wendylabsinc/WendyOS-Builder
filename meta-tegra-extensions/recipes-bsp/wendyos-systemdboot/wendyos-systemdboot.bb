SUMMARY = "WendyOS systemd-boot A/B boot stack for Jetson (Orin)"
DESCRIPTION = "Stages systemd-boot (systemd-bootaa64.efi) + loader.conf + the two \
A/B loader entries (slot-a/slot-b) and the per-slot kernels onto the writable ESP \
on first boot, and enrolls a UEFI Boot#### for systemd-boot as the first \
BootOrder entry — keeping L4TLauncher as a lower-priority fallback so the device \
can never be left unbootable. This replaces NVIDIA's OS-unarmable firmware rootfs \
A/B (RootfsRedundancyLevel EINVAL on Orin) with systemd-boot's native +tries boot \
counting, whose state is a file-name rename on the FAT ESP (no runtime EFI-var \
persistence required). The wendyos-update systemdboot connector drives the slot \
selection at runtime. Only built into the image on the systemd-boot A/B boot path \
(WENDYOS_TEGRA_SYSTEMDBOOT_AB = 1)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://loader.conf \
    file://slot-a.conf \
    file://slot-b.conf \
    file://wendyos-systemdboot-firstboot.sh \
    file://wendyos-systemdboot-firstboot.service \
    "
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "(tegra)"

inherit systemd

SYSTEMD_SERVICE:${PN} = "wendyos-systemdboot-firstboot.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # loader.conf + the two A/B entry templates: the first-boot service copies
    # these onto the ESP (renaming the entries to slot-<x>+3.conf).
    install -d ${D}${libdir}/wendyos-systemdboot
    install -m 0644 ${UNPACKDIR}/loader.conf ${D}${libdir}/wendyos-systemdboot/loader.conf
    install -m 0644 ${UNPACKDIR}/slot-a.conf ${D}${libdir}/wendyos-systemdboot/slot-a.conf
    install -m 0644 ${UNPACKDIR}/slot-b.conf ${D}${libdir}/wendyos-systemdboot/slot-b.conf

    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-systemdboot-firstboot.sh \
        ${D}${sbindir}/wendyos-systemdboot-firstboot

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/wendyos-systemdboot-firstboot.service \
        ${D}${systemd_system_unitdir}/
}

# systemd-boot provides systemd-bootaa64.efi (staged to the ESP) + bootctl /
# systemd-bless-boot (used by the wendyos-update connector); efibootmgr registers
# the Boot####. efivarfs is in-kernel.
RDEPENDS:${PN} = "systemd systemd-boot efibootmgr"

FILES:${PN} += " \
    ${libdir}/wendyos-systemdboot \
    ${sbindir}/wendyos-systemdboot-firstboot \
    ${systemd_system_unitdir}/wendyos-systemdboot-firstboot.service \
    "

# ============================================================================
# BIGGEST RISK — DEVICE TREE. READ BEFORE TAKING THIS PAST THE SPIKE.
# ============================================================================
# This recipe ships the SIMPLE Type #1 layout (loader/entries/slot-<x>.conf with
# `linux`/`initrd`/`options`). Type #1 entries have NO `devicetree` line here on
# purpose: systemd-boot's `devicetree` key hands the DTB to the kernel via the
# EFI_DT_FIXUP_PROTOCOL, which NVIDIA's edk2 (L4T UEFI) does NOT implement — so a
# `devicetree` line would be silently ignored and the kernel would come up with
# the WRONG (or no) device tree. On Jetson today L4TLauncher/extlinux passes the
# DTB (and NVIDIA's runtime-generated overlays) through a Tegra-specific path that
# systemd-boot does not reproduce. This is UNVERIFIED on hardware and is the most
# likely reason a first boot via systemd-boot fails.
#
# RECOMMENDED FOLLOW-UP (do NOT attempt in this spike): build a UKI (Unified
# Kernel Image) per slot with the merged DTB embedded, using systemd-stub. That
# requires the kernel built with CONFIG_EFI_ZBOOT=y and the base DTB (plus any
# required overlays, merged AT BUILD TIME) bundled into the .efi via the stub's
# `.dtb` PE section. The `+tries` boot counter then lives on the UKI file name in
# EFI/Linux/ (e.g. EFI/Linux/slot-a+3.efi) instead of on the .conf, and the
# wendyos-update systemdboot connector's entry-rename logic works unchanged
# (same slot-<x>[+tries] naming, different directory/extension).
#
# The hard, DEFERRED sub-problem is NVIDIA's runtime DTB OVERLAYS (kernel-dtb
# overlays / pinmux / plugin-manager applied by cboot/UEFI at boot). A build-time
# UKI freezes one merged DTB and does NOT reproduce that runtime overlay merge.
# Solving overlay-merge is explicitly OUT OF SCOPE here and must be designed
# separately before this ships to hardware.
# ============================================================================
