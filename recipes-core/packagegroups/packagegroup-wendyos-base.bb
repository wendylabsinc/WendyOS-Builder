
PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

SUMMARY:${PN} = "Base support"
RDEPENDS:${PN} = " \
    packagegroup-core-boot \
    bash \
    coreutils \
    libstdc++ \
    file \
    util-linux \
    iproute2 \
    lsof \
    networkmanager \
    networkmanager-nmcli \
    vim \
    htop \
    usbutils \
    tree \
    util-linux-fdisk \
    avahi-daemon \
    avahi-wendyos-hostname \
    avahi-utils \
    jq \
    wendyos-identity \
    wendyos-agent \
    wendyos-user \
    wendyos-motd \
    containerd-config \
    xdg-dbus-proxy \
    "

# Recipes that bind-mount or otherwise depend on the /data partition the
# OTA stack provides. Gated on WENDYOS_OTA != "none" (set in wendyos.conf):
# with no OTA stack (e.g. QEMU) there is no /data partition and these
# services would fail at boot.
RDEPENDS:${PN}:append = " \
    ${@'' if (d.getVar('WENDYOS_OTA') or 'none') == 'none' else \
        'wendyos-user-data-setup systemd-mount-containerd swapfile-setup wendyos-etc-binds'} \
    "

RDEPENDS:${PN}:append = " \
    ${@oe.utils.ifelse( \
        d.getVar('WENDYOS_DEBUG') == '1', \
        ' \
            tcpdump \
            gzip \
        ', \
        '' \
        )} \
    "

# Include hardware-specific packagegroup configuration
require ${@'qemu-packagegroup-base.inc'  if 'qemuall' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'tegra-packagegroup-base.inc' if 'tegra'   in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'packagegroup-base-rpi.inc'   if 'rpi'     in d.getVar('MACHINEOVERRIDES').split(':') else ''}
