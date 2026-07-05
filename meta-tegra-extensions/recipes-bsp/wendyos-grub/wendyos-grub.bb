SUMMARY = "WendyOS A/B GRUB2 payload (grubaa64.efi + grub.cfg + grubenv) for Jetson"
DESCRIPTION = "Stages the GRUB2 A/B boot stack into the image for the first-boot \
enroll service: the self-contained grubaa64.efi built by oe-core grub-efi (with \
the A/B modules embedded via GRUB_BUILDIN), the A/B grub.cfg (RAUC grub.conf \
model — pick the first ORDER slot with <S>_OK=1 && <S>_TRY=0, one-shot TRY \
trial, fall back otherwise), and a pre-created grubenv seeded to boot slot A. \
These are shipped under ${libdir}/wendyos-grub (a staging area, NOT the ESP); \
wendyos-grub-firstboot copies them onto the mounted ESP and enrolls BootOrder. \
Only built into the image on the GRUB A/B boot path (WENDYOS_TEGRA_GRUB_AB = 1)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = "file://grub.cfg"
S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "(tegra)"

# grub-efi builds the aarch64 EFI application (grubaa64.efi) with GRUB_BUILDIN
# modules embedded (set in the machine conf); grub-native provides grub-editenv
# to pre-create the grubenv block at build time.
DEPENDS = "grub-efi grub-native"

# Pull the freshly built EFI app out of grub-efi's deploy step.
do_install[depends] += "grub-efi:do_deploy"

# Pre-create + seed the grubenv (a fixed 1024-byte GRUB environment block).
# Initial state: slot A is the factory-good slot, B is empty. grub.cfg boots A,
# and the wendyos-update grubenv connector arms B on the first OTA.
do_compile() {
    grub-editenv ${B}/grubenv create
    grub-editenv ${B}/grubenv set ORDER="A B" A_OK=1 A_TRY=0 B_OK=0 B_TRY=0
}

do_install() {
    install -d ${D}${libdir}/wendyos-grub

    # grub-efi deploys the built aarch64 EFI application into DEPLOY_DIR_IMAGE.
    # Its exact filename is set by grub-efi.bbclass (${GRUB_IMAGE}); glob to be
    # resilient to prefix/name differences across oe-core versions, then install
    # it under the canonical grubaa64.efi the first-boot service expects.
    src="$(ls -1 ${DEPLOY_DIR_IMAGE}/grub-efi-bootaa64.efi \
                 ${DEPLOY_DIR_IMAGE}/grubaa64.efi \
                 ${DEPLOY_DIR_IMAGE}/*aa64.efi 2>/dev/null | head -n1)"
    if [ -z "${src}" ] || [ ! -f "${src}" ]; then
        bbfatal "grub-efi did not deploy an aarch64 EFI image to ${DEPLOY_DIR_IMAGE}"
    fi
    install -m 0644 "${src}" ${D}${libdir}/wendyos-grub/grubaa64.efi

    install -m 0644 ${UNPACKDIR}/grub.cfg ${D}${libdir}/wendyos-grub/grub.cfg
    install -m 0644 ${B}/grubenv          ${D}${libdir}/wendyos-grub/grubenv
}

FILES:${PN} = " \
    ${libdir}/wendyos-grub/grubaa64.efi \
    ${libdir}/wendyos-grub/grub.cfg \
    ${libdir}/wendyos-grub/grubenv \
    "

# The staged EFI app is a prebuilt binary from grub-efi; nothing to strip/scan.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_SYSROOT_STRIP = "1"
EXCLUDE_FROM_SHLIBS = "1"
