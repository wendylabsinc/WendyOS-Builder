
DESCRIPTION = "WendyOS Image"
LICENSE = "MIT"

inherit core-image

# Note: mender-full is inherited via conf/distro/include/mender.inc
# which is conditionally included in wendyos.conf (not for QEMU)

DISTRO_FEATURES:append = " systemd"
VIRTUAL-RUNTIME_init_manager = "systemd"

# Make this image also produce an ext4 alongside tegraflash/mender/dataimg
IMAGE_FSTYPES += " ext4"

# Release-style naming for this image:
# - IMAGE_VERSION_SUFFIX is a common pattern to carry a release tag.
# - If unset, it falls back to DISTRO_VERSION.
IMAGE_VERSION_SUFFIX ?= "${DISTRO_VERSION}"

# Mender artifact name and configuration live in conf/distro/include/mender.inc,
# which is conditionally required when WENDYOS_OTA = "mender" (see wendyos.conf).
# Defining them here unconditionally would leave dangling vars on machines
# where Mender is disabled (Thor, QEMU, RPi).

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

# The classic debug-tweaks credential set (empty/passwordless root + autologin)
# that #172 removed from WENDYOS_DEBUG_FEATURES. Reintroduced ONLY for dev/PR
# builds, gated strictly on WENDYOS_DEV_LOGIN (never WENDYOS_DEBUG). Without a
# working credential the restored getty would be unusable (root is otherwise
# locked to root:*: by zap_empty_root_password).
WENDYOS_DEV_LOGIN_FEATURES ?= " \
    empty-root-password \
    allow-empty-password \
    allow-root-login \
    "
IMAGE_FEATURES += "${@oe.utils.ifelse(d.getVar('WENDYOS_DEV_LOGIN') == '1', d.getVar('WENDYOS_DEV_LOGIN_FEATURES'), '')}"

# No local interactive login on ANY image (debug included). A physically
# attached monitor+keyboard (VT: getty@tty1 plus logind's autovt@ VT-switch
# spawns) and the serial console login (serial-getty@, driven by
# SERIAL_CONSOLES) are both an attack surface on a product device and are
# removed. The kernel `console=` bootarg (boot + printk output on UART, not a
# getty/login prompt) is a separate knob lit per-machine in the bootarg wiring,
# not here: on Raspberry Pi it is gated on WENDYOS_DEBUG_UART (see
# meta-rpi-extensions' rpi-cmdline.bbappend), so RPi fortress builds (the "0"
# default) get no serial boot output and dev/PR builds (WENDYOS_DEBUG_UART="1")
# restore it. Tegra console gating on the same knob is still pending (task A2),
# so Jetson builds currently emit serial boot output regardless of this flag.
# Either way that is independent of WENDYOS_DEV_LOGIN's login-prompt gate below.
# Device access is exclusively via the wendy-agent (gRPC); there is no
# interactive login path (SSH stays off).
#
# Masking these units in the rootfs is fatal: systemd's 90-systemd.preset
# enables getty@/serial-getty@ and the rootfs preset-all pass rejects "enable a
# masked unit". So preset-disable the templates (a 10- file wins over 90-),
# drop any enablement symlinks a postinst force-created, and zero logind's
# auto-VTs (which also stops the autovt@ VT-switch spawns a preset alone can't
# reach).
disable_local_login() {
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/getty.target.wants/getty@*.service
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/getty.target.wants/serial-getty@*.service
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/getty.target.wants/console-getty.service
    install -d ${IMAGE_ROOTFS}${systemd_unitdir}/system-preset
    printf 'disable getty@.service\ndisable autovt@.service\ndisable serial-getty@.service\ndisable console-getty.service\n' \
        > ${IMAGE_ROOTFS}${systemd_unitdir}/system-preset/10-wendyos-no-local-login.preset
    install -d ${IMAGE_ROOTFS}${systemd_unitdir}/logind.conf.d
    printf '[Login]\nNAutoVTs=0\nReserveVT=0\n' \
        > ${IMAGE_ROOTFS}${systemd_unitdir}/logind.conf.d/10-wendyos-no-autovt.conf
}
# Fortress (release + nightly): strip every local login path. Dev/PR builds
# (WENDYOS_DEV_LOGIN="1") keep getty/serial-getty so the PR is debuggable.
ROOTFS_POSTPROCESS_COMMAND += "${@'' if d.getVar('WENDYOS_DEV_LOGIN') == '1' else 'disable_local_login;'}"

# Stamp build provenance onto the console boot screen (base-files' /etc/issue,
# shown under the WendyOS logo before the login prompt). The build tag/ID is
# shown on every build; the builder commit is added only on PR/dev builds, gated
# on WENDYOS_DEV_LOGIN (CI sets it only for pull_request). WENDYOS_BUILD_* come
# from auto.conf on CI and fall back to DISTRO_VERSION / "" locally (common.inc).
# Runs after base-files installs /etc/issue, so the file is present to append to.
stamp_boot_screen() {
    issue="${IMAGE_ROOTFS}${sysconfdir}/issue"
    [ -f "$issue" ] || return 0
    printf 'Build: %s\n' "${WENDYOS_BUILD_VERSION}" >> "$issue"
    if [ "${WENDYOS_DEV_LOGIN}" = "1" ] && [ -n "${WENDYOS_BUILD_COMMIT}" ]; then
        printf 'Commit: %s\n' "${WENDYOS_BUILD_COMMIT}" >> "$issue"
    fi
}
ROOTFS_POSTPROCESS_COMMAND += "stamp_boot_screen;"

# Optional runtime package management (rpm/dnf in the rootfs).
# Disabled by default — image is updated atomically via Mender A/B.
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

# Mender userspace packages — gated on WENDYOS_OTA == "mender" (set in
# wendyos.conf and overridable per-machine). python3-pip-jetson-config
# lives in meta-tegra-extensions, so it's split out as Tegra-only.
IMAGE_INSTALL:append = " \
    ${@'mender-configure mender-connect' if d.getVar('WENDYOS_OTA') == 'mender' else ''} \
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
    WENDYOS_DEV_LOGIN \
    WENDYOS_SSHD \
    WENDYOS_USB_GADGET \
    WENDYOS_USB_NET_MODE \
    WENDYOS_MDNS_INTERFACES \
    WENDYOS_PERSIST_JOURNAL_LOGS \
    WENDYOS_UPDATE_BOOTLOADER \
    WENDYOS_DEEPSTREAM \
    WENDYOS_BUILD_VERSION \
    WENDYOS_BUILD_COMMIT \
    "

# Include hardware-specific image configuration
# These files contain IMAGE_INSTALL modifications and other hardware-specific settings
require ${@'conf/distro/include/qemu-image.inc' if 'qemuall' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'conf/distro/include/tegra-image.inc' if 'tegra' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'conf/distro/include/rpi-image.inc' if 'rpi' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
