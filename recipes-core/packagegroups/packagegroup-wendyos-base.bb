
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
    usb-power-config \
    "

# Recipes that bind-mount or otherwise depend on the /data partition the
# OTA stack provides. Gated on WENDYOS_OTA != "none" (set in wendyos.conf):
# with no OTA stack (e.g. QEMU) there is no /data partition and these
# services would fail at boot.
RDEPENDS:${PN}:append = " \
    ${@'' if (d.getVar('WENDYOS_OTA') or 'none') == 'none' else \
        'wendyos-user-data-setup systemd-mount-containerd systemd-mount-wendy swapfile-setup wendyos-etc-binds'} \
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

# SocketCAN (kernel modules, plus can-utils in debug images). Gated on
# WENDYOS_CAN: on for the robotics targets, off for QEMU. The per-family
# defaults live in conf/distro/include/{rpi,x86,qemu}-distro.inc for those three
# and in conf/template/include/local/tegra-t{234,264}.inc for Jetson -- Tegra has
# no *-distro.inc, and tegra-image.inc is parsed too late to gate a recipe.
RDEPENDS:${PN}:append = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_CAN') == '1', 'packagegroup-wendyos-can', '')} \
    "

# Include hardware-specific packagegroup configuration
require ${@'qemu-packagegroup-base.inc'  if 'qemuall' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'tegra-packagegroup-base.inc' if 'tegra'   in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'packagegroup-base-rpi.inc'   if 'rpi'     in d.getVar('MACHINEOVERRIDES').split(':') else ''}
