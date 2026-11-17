# Orin: mount the root from the disk UEFI booted (BootCurrent), not only from the
# build-time TNSPEC_BOOTDEV disk, and never slot A's APP while the firmware runs slot B.
FILESEXTRAPATHS:prepend := "${THISDIR}/tegra-minimal-init:"
SRC_URI:append:tegra234 = " \
    file://wendyos-platform-preboot.sh \
    file://wendyos-init-boot.sh \
    file://wendyos-find-root.sh \
"

do_install:append:tegra234() {
    # The WendyOS copies are merged from these exact upstream scripts.
    sum=$(sha256sum ${UNPACKDIR}/init-boot.sh)
    [ "${sum%% *}" = "7a719a98f45bd0d526df2e2f07e884a5af51050fb7aa965dc3b6a1975cee09a8" ] || \
        bbfatal "upstream init-boot.sh changed; re-merge wendyos-init-boot.sh, then update the sha256"
    sum=$(sha256sum ${UNPACKDIR}/platform-preboot.sh)
    [ "${sum%% *}" = "4423a2f418d8f9d529b2650a85bf59e8edb2a8aed564e2bd1c908417b49e1875" ] || \
        bbfatal "upstream platform-preboot.sh changed; re-merge wendyos-platform-preboot.sh, then update the sha256"

    # Only a whole disk, as meta-tegra derives it: a partition here silently drops the bootdrive fallback.
    case "${TEGRA_MINIMAL_INIT_BOOTDRIVE}" in
        "" | /dev/mmcblk[0-9] | /dev/mmcblk[0-9][0-9] | /dev/nvme[0-9]n[0-9] | /dev/nvme[0-9]n[0-9][0-9] | /dev/sd[a-z]) ;;
        *) bbfatal "TEGRA_MINIMAL_INIT_BOOTDRIVE must be empty or a whole disk such as /dev/nvme0n1" ;;
    esac

    install -m 0755 ${UNPACKDIR}/wendyos-init-boot.sh ${D}/init
    install -m 0644 ${UNPACKDIR}/wendyos-platform-preboot.sh ${D}${sysconfdir}/platform-preboot
    sed -i -e "s#@@BOOTDRIVE@@#${TEGRA_MINIMAL_INIT_BOOTDRIVE}#g" \
        -e "s#@@FINDROOT@@#${base_sbindir}/wendyos-find-root#g" \
        ${D}${sysconfdir}/platform-preboot
    if grep -q '@@' ${D}${sysconfdir}/platform-preboot; then
        bbfatal "unsubstituted @@ token left in platform-preboot"
    fi
    install -d ${D}${base_sbindir}
    install -m 0755 ${UNPACKDIR}/wendyos-find-root.sh ${D}${base_sbindir}/wendyos-find-root
}
