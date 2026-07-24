
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

# Development-time conveniences applied when WENDYOS_DEBUG = "1": postinst
# logging. Formerly this bundle also carried empty-root-password,
# allow-empty-password and allow-root-login (scarthgap's legacy `debug-tweaks`
# alias, expanded into individual features because wrynose oe-core removed the
# alias from IMAGE_FEATURES[validitems]). Those root/empty-password features
# were deliberately dropped: direct root login is now disabled on every image,
# debug included. With empty-root-password gone, OE-core's
# zap_empty_root_password rewrites the empty root entry to `root:*:` (a locked
# account with no valid password) on all builds, and no allow-root-login means
# sshd is never told PermitRootLogin yes. Override WENDYOS_DEBUG_FEATURES in
# local.conf if a downstream build genuinely needs them back.
WENDYOS_DEBUG_FEATURES ?= " \
    post-install-logging \
    "
IMAGE_FEATURES += "${@oe.utils.ifelse(d.getVar('WENDYOS_DEBUG') == '1', d.getVar('WENDYOS_DEBUG_FEATURES'), '')}"

# Local interactive login is an attack surface on a product device, so every
# getty is disabled by default and each console type is separately opt-in. No
# login implies opening root: credentials are a separate concern — root stays
# locked (root:*: on every image via zap_empty_root_password); log in as the
# wendy user, which has passwordless sudo.
#
#   getty@ + autovt@ (+ logind auto-VTs)       -> monitor/keyboard VT login
#                                                 WENDYOS_ENABLE_VT_LOGIN (default 0)
#   serial-getty@<port> (from SERIAL_CONSOLES) -> named serial login
#                                                 WENDYOS_ENABLE_UART_LOGIN (default 0; CI opts in on PR)
#   console-getty (login on /dev/console)      -> the LAST console= on the
#       cmdline: the serial port on Tegra/RPi/qemu, but tty0 (the VT) on x86.
#       Grouped per board via WENDYOS_CONSOLE_LOGIN_TYPE so the operator's
#       UART/VT choice governs the login they actually get. (Tegra sets no
#       SERIAL_CONSOLES, so console-getty *is* its serial login — keep it UART.)
#
# The kernel `console=` bootarg (boot + printk output, not a getty) is separate:
# on RPi it is gated on WENDYOS_DEBUG_UART (rpi-cmdline.bbappend); Tegra emits it
# regardless (task A2). Independent of the login knobs here.
#
# Masking is fatal: systemd's 90-systemd.preset enables getty@/serial-getty@ and
# the rootfs preset-all pass rejects "enable a masked unit". So preset-disable
# (a 10- file beats 90-) + drop any enablement symlinks; VT additionally zeroes
# logind's auto-VTs (stops the autovt@ VT-switch spawns a preset can't reach).

# console-getty logs in on /dev/console, whose identity is board-specific:
# serial-console boards -> group with UART; x86 (console=tty0) -> group with VT.
WENDYOS_CONSOLE_LOGIN_TYPE ?= "uart"
WENDYOS_CONSOLE_LOGIN_TYPE:x86-wendyos = "vt"

disable_vt_login() {
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/getty.target.wants/getty@*.service
    install -d ${IMAGE_ROOTFS}${systemd_unitdir}/system-preset
    printf 'disable getty@.service\ndisable autovt@.service\n' \
        > ${IMAGE_ROOTFS}${systemd_unitdir}/system-preset/10-wendyos-no-vt-login.preset
    install -d ${IMAGE_ROOTFS}${systemd_unitdir}/logind.conf.d
    printf '[Login]\nNAutoVTs=0\nReserveVT=0\n' \
        > ${IMAGE_ROOTFS}${systemd_unitdir}/logind.conf.d/10-wendyos-no-autovt.conf
}

disable_uart_login() {
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/getty.target.wants/serial-getty@*.service
    install -d ${IMAGE_ROOTFS}${systemd_unitdir}/system-preset
    printf 'disable serial-getty@.service\n' \
        > ${IMAGE_ROOTFS}${systemd_unitdir}/system-preset/10-wendyos-no-uart-login.preset
}

disable_console_getty() {
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/getty.target.wants/console-getty.service
    install -d ${IMAGE_ROOTFS}${systemd_unitdir}/system-preset
    printf 'disable console-getty.service\n' \
        > ${IMAGE_ROOTFS}${systemd_unitdir}/system-preset/10-wendyos-no-console-getty.preset
}

# console-getty is governed by the knob matching its board grouping.
WENDYOS_CONSOLE_GETTY_KNOB = "${@d.getVar('WENDYOS_ENABLE_VT_LOGIN') if d.getVar('WENDYOS_CONSOLE_LOGIN_TYPE') == 'vt' else d.getVar('WENDYOS_ENABLE_UART_LOGIN')}"

# Each gate bakes its command in/out, so the do_rootfs signature tracks the knob
# and the image rebuilds when a knob changes.
ROOTFS_POSTPROCESS_COMMAND += "${@oe.utils.ifelse(d.getVar('WENDYOS_ENABLE_VT_LOGIN') == '1', '', 'disable_vt_login;')}"
ROOTFS_POSTPROCESS_COMMAND += "${@oe.utils.ifelse(d.getVar('WENDYOS_ENABLE_UART_LOGIN') == '1', '', 'disable_uart_login;')}"
ROOTFS_POSTPROCESS_COMMAND += "${@oe.utils.ifelse(d.getVar('WENDYOS_CONSOLE_GETTY_KNOB') == '1', '', 'disable_console_getty;')}"

# Stamp build provenance onto the console boot screen (base-files' /etc/issue,
# shown under the WendyOS logo before the login prompt). The build tag/ID is
# shown on every build; the builder commit is added only on PR builds, keyed on
# the CI version tag (WENDYOS_BUILD_VERSION = "pr-<N>" on pull_request, else
# nightly-<ts> / X.Y.Z). WENDYOS_BUILD_* come from auto.conf on CI and fall back
# to DISTRO_VERSION / "" locally (common.inc). Runs after base-files installs
# /etc/issue, so the file is present to append to.
stamp_boot_screen() {
    issue="${IMAGE_ROOTFS}${sysconfdir}/issue"
    [ -f "$issue" ] || return 0
    printf 'Build: %s\n' "${WENDYOS_BUILD_VERSION}" >> "$issue"
    case "${WENDYOS_BUILD_VERSION}" in
        pr-*) [ -n "${WENDYOS_BUILD_COMMIT}" ] && printf 'Commit: %s\n' "${WENDYOS_BUILD_COMMIT}" >> "$issue" ;;
    esac
}
ROOTFS_POSTPROCESS_COMMAND += "stamp_boot_screen;"

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

# Driver add-ons (systemd-sysext): boot-time service that merges driver .raw
# add-ons from /data. Gated on WENDYOS_DRIVER_EXTENSIONS (RPi-only for now).
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_DRIVER_EXTENSIONS') == '1', ' wendyos-sysext-apply', '')} \
    "

# Note: gadget-network-config (standalone dnsmasq) removed.
# USB gadget IPv4 mode is controlled by WENDYOS_USB_NET_MODE (see wendyos.conf).

IMAGE_ROOTFS_SIZE ?= "8192"
# Extra free space only on content-sized builds. When the image size is pinned
# (WENDYOS_ROOTFS_SIZE_KB, wendyos-rootfs-size.inc) the fixed size IS the
# headroom — and get_rootfs_size() adds EXTRA_SPACE *after* the
# IMAGE_ROOTFS_SIZE floor, so an unconditional append would push every pinned
# build past the floor==ceiling limit and fail it. This :append lands after the
# include's :pn- override, hence the gate must live here.
IMAGE_ROOTFS_EXTRA_SPACE:append = "${@' + 4096' if bb.utils.contains('DISTRO_FEATURES', 'systemd', True, False, d) and not d.getVar('WENDYOS_ROOTFS_SIZE_KB') else ''}"

# A space-separated list of variable names that BitBake prints in the
# "Build Configuration" banner at the start of a build.
BUILDCFG_VARS += " \
    WENDYOS_OTA \
    WENDYOS_DATA_PART \
    WENDYOS_DEBUG \
    WENDYOS_DEBUG_UART \
    WENDYOS_ENABLE_UART_LOGIN \
    WENDYOS_ENABLE_VT_LOGIN \
    WENDYOS_SSHD \
    WENDYOS_USB_GADGET \
    WENDYOS_USB_NET_MODE \
    WENDYOS_MDNS_INTERFACES \
    WENDYOS_PERSIST_JOURNAL_LOGS \
    WENDYOS_UPDATE_BOOTLOADER \
    WENDYOS_DEEPSTREAM \
    WENDYOS_NVIDIA_DGPU \
    WENDYOS_BUILD_VERSION \
    WENDYOS_BUILD_COMMIT \
    "

# Include hardware-specific image configuration
# These files contain IMAGE_INSTALL modifications and other hardware-specific settings
require ${@'conf/distro/include/qemu-image.inc' if 'qemuall' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'conf/distro/include/tegra-image.inc' if 'tegra' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'conf/distro/include/rpi-image.inc' if 'rpi' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'conf/distro/include/x86-image.inc' if 'x86-wendyos' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
