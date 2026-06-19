# RPi base-files extensions.
# Included conditionally from base-files_%.bbappend — safe for non-RPi machines.

inherit partuuid-rpi
inherit journal-persist-rpi

SRC_URI:append = " file://rpi-fstab file://rpi-mbr-fstab file://rpi-wendy-fstab"

# RPi4/5 boot from a GPT image and reference partitions by PARTUUID (rpi-fstab,
# placeholders RPI_BOOT_UUID / RPI_ROOT_UUID get substituted below).
# RPi3 boots from MBR (BCM2837 GPU bootrom limitation) and references
# partitions by filesystem label; the MBR template has no placeholders, so the
# substitution sed lines below are no-ops on that path.
#
# Pinned to :raspberrypi3-64 to mirror the override used in rpi-cmdline.bbappend
# (see comment there). WendyOS only ships the 64-bit RPi3 image; if a 32-bit
# variant is ever added, both overrides will need a matching :raspberrypi3 entry.
RPI_FSTAB_TEMPLATE = "rpi-fstab"
RPI_FSTAB_TEMPLATE:raspberrypi3-64 = "rpi-mbr-fstab"

do_install:append() {
    if [ "${WENDYOS_OTA}" = "wendy" ]; then
        # wendyos-update A/B layout (RPi5): no Mender postprocess to generate
        # fstab. Install our A/B fstab (no "/" entry — the kernel mounts the
        # slot via boot-ab.cmd.in's root=; /boot stays mounted for fw_setenv's
        # uboot.env; /data + /config by label). Only RPI_BOOT_UUID is
        # substituted; /config and /data use LABEL=.
        install -m 0644 ${WORKDIR}/rpi-wendy-fstab ${D}${sysconfdir}/fstab
        sed -i "s/RPI_BOOT_UUID/${WENDYOS_BOOT_PARTUUID}/g" ${D}${sysconfdir}/fstab
    elif [ "${WENDYOS_RPI_UBOOT}" = "1" ]; then
        # Mender-managed MBR layout: boot/A/B/extended{config,data}. The
        # poky-stock /etc/fstab (already installed by base-files's own
        # do_install) is correct here — the kernel mounts / via the
        # ${mender_kernel_root} cmdline arg, and Mender's image-build
        # postprocess appends /data and /uboot (the wendyos-image bbappend
        # fixes up the /config line). Our rpi-fstab hard-codes /boot and
        # /config entries that don't match this layout, so we skip it here.
        :
    else
        install -m 0644 ${WORKDIR}/${RPI_FSTAB_TEMPLATE} ${D}${sysconfdir}/fstab
        sed -i "s/RPI_BOOT_UUID/${WENDYOS_BOOT_PARTUUID}/g" ${D}${sysconfdir}/fstab
        sed -i "s/RPI_ROOT_UUID/${WENDYOS_ROOT_PARTUUID}/g" ${D}${sysconfdir}/fstab
    fi
}

# Trigger a rebuild whenever the inputs to fstab generation change
do_install[vardeps] += " WENDYOS_BOOT_PARTUUID WENDYOS_ROOT_PARTUUID RPI_FSTAB_TEMPLATE WENDYOS_RPI_UBOOT WENDYOS_OTA"

# systemd persistent log
# If /var/log is a symlink into /var/volatile/log, journald cannot persist logs
# and packaging any /var/log/* triggers a "directory symlink" QA error.
do_install:append:journal_persist-on() {
    if [ -L ${D}${localstatedir}/log ]; then
        rm -f ${D}${localstatedir}/log
        install -d -m 0755 ${D}${localstatedir}/log
    fi
}
