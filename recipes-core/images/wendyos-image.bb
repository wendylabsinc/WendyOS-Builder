
DESCRIPTION = "WendyOS Image"
LICENSE = "MIT"

inherit core-image

DISTRO_FEATURES:append = " systemd"
VIRTUAL-RUNTIME_init_manager = "systemd"

# Make this image also produce an ext4 alongside tegraflash
IMAGE_FSTYPES += " ext4"

# Release-style naming for this image:
# - IMAGE_VERSION_SUFFIX is a common pattern to carry a release tag.
# - If unset, it falls back to DISTRO_VERSION.
IMAGE_VERSION_SUFFIX ?= "${DISTRO_VERSION}"

# Development-time conveniences applied when WENDYOS_DEBUG = "1": empty
# root password, PermitEmptyPasswords, PermitRootLogin, postinst logging.
# Equivalent to scarthgap's legacy `debug-tweaks` alias, expanded into
# individual features here because wrynose oe-core removed the alias from
# IMAGE_FEATURES[validitems]. Override WENDYOS_DEBUG_FEATURES in local.conf
# to add/remove features from the debug bundle.
WENDYOS_DEBUG_FEATURES ?= " \
    empty-root-password \
    allow-empty-password \
    allow-root-login \
    post-install-logging \
    "
IMAGE_FEATURES += "${@oe.utils.ifelse(d.getVar('WENDYOS_DEBUG') == '1', d.getVar('WENDYOS_DEBUG_FEATURES'), '')}"

# No interactive login on an attached monitor+keyboard unless WENDYOS_DEBUG = "1".
# systemd ships an enabled getty@tty1.service, and logind spawns further gettys
# on VT switch (autovt@ttyN resolves to the getty@ template). Root is already
# locked on release builds (no empty-root-password above), but the prompt itself
# is still an attack surface on a product device.
#
# Do NOT mask getty@.service here: `systemctl --root preset-all` (run by
# rootfs-postcommands' systemd_handle_machine_id during rootfs assembly)
# errors on a masked unit it has an enable preset for, failing do_rootfs
# ("Failed to preset all unit: ... is masked"). Instead:
#   - a system-preset that DISABLES getty@ outranks systemd's default
#     enable preset, so preset-all neither errors nor re-enables it;
#   - the enablement symlink is removed for the assembled image;
#   - a drop-in condition neuters logind's autovt@ttyN spawns (they start
#     the getty@ template directly, ignoring enablement) — the unit starts,
#     the condition fails, no prompt appears, nothing loops.
# Serial consoles (serial-getty@, SERIAL_CONSOLES) are deliberately
# untouched so UART access stays available for field debugging. To restore
# VT logins on a device: touch /etc/wendyos/enable-vt-login, re-enable
# getty@tty1, reboot.
disable_vt_login() {
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/getty.target.wants/getty@tty1.service
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system-preset
    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system-preset/50-wendyos-no-vt-login.preset <<EOF
disable getty@.service
disable getty@*.service
EOF
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/getty@.service.d
    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/getty@.service.d/10-wendyos-no-vt-login.conf <<EOF
[Unit]
# VT logins disabled on release builds (wendyos-image.bb disable_vt_login).
# Touch this file and reboot to get a VT login prompt for debugging.
ConditionPathExists=/etc/wendyos/enable-vt-login
EOF
}
ROOTFS_POSTPROCESS_COMMAND += "${@oe.utils.ifelse(d.getVar('WENDYOS_DEBUG') == '1', '', 'disable_vt_login;')}"

# Optional runtime package management (rpm/dnf in the rootfs).
# Disabled by default — image is updated atomically via the A/B OTA.
# Set WENDYOS_ENABLE_PACKAGE_MANAGEMENT = "1" in local.conf or distro to enable.
IMAGE_FEATURES += "${@bb.utils.contains('WENDYOS_ENABLE_PACKAGE_MANAGEMENT', '1', 'package-management', '', d)}"

# OpenSSH server (sshd). Controlled by WENDYOS_SSHD (default: "0").
# Set WENDYOS_SSHD = "1" in local.conf to include sshd in the image.
IMAGE_FEATURES += "${@oe.utils.ifelse(d.getVar('WENDYOS_SSHD') == '1', 'ssh-server-openssh', '')}"

# Common packages for all machines (real hardware and QEMU)
IMAGE_INSTALL:append = " \
    packagegroup-wendyos-base \
    packagegroup-wendyos-kernel \
    packagegroup-wendyos-debug \
    nerdctl \
    bluez5 \
    bluez5-obex \
    pipewire \
    wireplumber \
    pipewire-pulse \
    pipewire-alsa \
    pipewire-v4l2 \
    rtkit \
    audio-config \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    "

# python3-pip-jetson-config lives in meta-tegra-extensions, so it's Tegra-only.
IMAGE_INSTALL:append = " \
    ${@'python3-pip-jetson-config' if 'tegra' in d.getVar('MACHINEOVERRIDES').split(':') else ''} \
    "

# Enable USB peripheral (gadget) support for real hardware
# Controlled by WENDYOS_USB_GADGET variable (not needed for QEMU)
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse( \
        d.getVar('WENDYOS_USB_GADGET') == '1', \
            ' \
                gadget-setup \
                usb-gadget-modules \
                usb-network-tuning \
                e2fsprogs-mke2fs \
                util-linux-mount \
            ', \
            '' \
        )} \
    "

# Container runtime (containerd + nerdctl + CNI). Default in wendyos.conf;
# any machine can opt out with WENDYOS_CONTAINER_RUNTIME = "0".
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_CONTAINER_RUNTIME') == '1', ' packagegroup-wendyos-container', '')} \
    "

# Note: gadget-network-config (standalone dnsmasq) removed.
# USB gadget IPv4 mode is controlled by WENDYOS_USB_NET_MODE (see wendyos.conf).

IMAGE_ROOTFS_SIZE ?= "8192"
# Extra free space only on content-sized builds. When the image size is
# pinned (WENDYOS_ROOTFS_SIZE_KB, wendyos-rootfs-size.inc) the fixed size IS
# the headroom — and get_rootfs_size() adds EXTRA_SPACE *after* the
# IMAGE_ROOTFS_SIZE floor, so an unconditional append would push every pinned
# build past the floor==ceiling limit and fail it. This :append lands after
# the include's :pn- override, hence the gate must live here.
IMAGE_ROOTFS_EXTRA_SPACE:append = "${@' + 4096' if bb.utils.contains('DISTRO_FEATURES', 'systemd', True, False, d) and not d.getVar('WENDYOS_ROOTFS_SIZE_KB') else ''}"

# A space-separated list of variable names that BitBake prints in the
# "Build Configuration" banner at the start of a build.
BUILDCFG_VARS += " \
    WENDYOS_OTA \
    WENDYOS_DATA_PART \
    WENDYOS_DEBUG \
    WENDYOS_DEBUG_UART \
    WENDYOS_SSHD \
    WENDYOS_USB_GADGET \
    WENDYOS_USB_NET_MODE \
    WENDYOS_MDNS_INTERFACES \
    WENDYOS_PERSIST_JOURNAL_LOGS \
    WENDYOS_UPDATE_BOOTLOADER \
    WENDYOS_DEEPSTREAM \
    "

# Include hardware-specific image configuration
# These files contain IMAGE_INSTALL modifications and other hardware-specific settings
require ${@'conf/distro/include/qemu-image.inc' if 'qemuall' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'conf/distro/include/tegra-image.inc' if 'tegra' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'conf/distro/include/rpi-image.inc' if 'rpi' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
