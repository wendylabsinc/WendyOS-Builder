# RPi base-files extensions.
# Included conditionally from base-files_%.bbappend — safe for non-RPi machines.

inherit partuuid-rpi
inherit journal-persist-rpi

SRC_URI:append = " \
    file://rpi-fstab \
    file://rpi-mbr-fstab \
    file://rpi-wendy-fstab \
    file://rpi-wendy-mbr-fstab \
    "

# RPi4/5 boot from a GPT image. /boot is referenced by filesystem LABEL (stable
# across builds — see WDY-1768); only the rootfs "/" still uses a substituted
# PARTUUID placeholder (RPI_ROOT_UUID, rpi-fstab only). RPi3 boots from MBR
# (BCM2837 GPU bootrom limitation) and references partitions by label too; its
# MBR template has no placeholder, so the RPI_ROOT_UUID sed is a no-op there.
#
# Pinned to :raspberrypi3-64 to mirror the override used in rpi-cmdline.bbappend
# (see comment there). WendyOS only ships the 64-bit RPi3 image; if a 32-bit
# variant is ever added, both overrides will need a matching :raspberrypi3 entry.
RPI_FSTAB_TEMPLATE = "rpi-fstab"
RPI_FSTAB_TEMPLATE:raspberrypi3-64 = "rpi-mbr-fstab"

# The wendy A/B fstab references /boot by LABEL on both GPT (RPi4/5) and MBR
# (RPi3): a baked PARTUUID drifts across builds since OTA only rewrites the
# rootfs slot and never re-partitions (WDY-1768), and PARTUUID won't resolve on
# MBR anyway. Same :raspberrypi3-64 pin rationale as above.
RPI_WENDY_FSTAB_TEMPLATE = "rpi-wendy-fstab"
RPI_WENDY_FSTAB_TEMPLATE:raspberrypi3-64 = "rpi-wendy-mbr-fstab"

do_install:append() {
    if [ "${WENDYOS_OTA}" = "wendy" ]; then
        # wendyos-update A/B layout (RPi3/4/5): nothing else generates the
        # fstab, so install our A/B fstab (no "/" entry — the kernel mounts the
        # slot via boot-ab.cmd.in's root=; /boot stays mounted for fw_setenv's
        # uboot.env). /boot, /config and /data are all referenced by LABEL, so
        # there is no placeholder to substitute on this path (WDY-1768).
        install -m 0644 ${UNPACKDIR}/${RPI_WENDY_FSTAB_TEMPLATE} ${D}${sysconfdir}/fstab
    elif [ "${WENDYOS_RPI_UBOOT}" = "1" ]; then
        # Legacy single-rootfs MBR layout: boot/A/B/extended{config,data}. The
        # poky-stock /etc/fstab (already installed by base-files's own
        # do_install) is correct here — the kernel mounts / via the
        # root= cmdline arg, and the image-build
        # postprocess appends /data and /uboot (the wendyos-image bbappend
        # fixes up the /config line). Our rpi-fstab hard-codes /boot and
        # /config entries that don't match this layout, so we skip it here.
        :
    else
        # /boot and /config are referenced by LABEL; only the rootfs "/" uses a
        # substituted PARTUUID here (WDY-1768).
        install -m 0644 ${UNPACKDIR}/${RPI_FSTAB_TEMPLATE} ${D}${sysconfdir}/fstab
        sed -i "s/RPI_ROOT_UUID/${WENDYOS_ROOT_PARTUUID}/g" ${D}${sysconfdir}/fstab
    fi
}

# Trigger a rebuild whenever the inputs to fstab generation change
do_install[vardeps] += " WENDYOS_ROOT_PARTUUID RPI_FSTAB_TEMPLATE RPI_WENDY_FSTAB_TEMPLATE WENDYOS_RPI_UBOOT WENDYOS_OTA"

# systemd persistent log
# If /var/log is a symlink into /var/volatile/log, journald cannot persist logs
# and packaging any /var/log/* triggers a "directory symlink" QA error.
do_install:append:journal_persist-on() {
    if [ -L ${D}${localstatedir}/log ]; then
        rm -f ${D}${localstatedir}/log
        install -d -m 0755 ${D}${localstatedir}/log
    fi
}

