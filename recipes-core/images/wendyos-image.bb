
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

# Keep names reproducible for releases.
# (Avoid DATETIME here unless you WANT a new artifact for every rebuild.)
MENDER_ARTIFACT_NAME = "${IMAGE_BASENAME}-${MACHINE}-${IMAGE_VERSION_SUFFIX}"
# MENDER_ARTIFACT_NAME = "${IMAGE_BASENAME}-${DISTRO_VERSION}-${DATETIME}"

# Mender configuration (only used when mender-full is inherited)
MENDER_UPDATE_POLL_INTERVAL_SECONDS    = "1800"
MENDER_INVENTORY_POLL_INTERVAL_SECONDS = "28800"
MENDER_RETRY_POLL_INTERVAL_SECONDS     = "300"
MENDER_SYSTEMD_AUTO_ENABLE = "1"
MENDER_CONNECT_ENABLE = "1"

# debug-tweaks: empty root password, PermitEmptyPasswords, PermitRootLogin.
# Controlled by WENDYOS_DEBUG (default: "0"). Set to "1" for development builds.
IMAGE_FEATURES += "${@oe.utils.ifelse(d.getVar('WENDYOS_DEBUG') == '1', 'debug-tweaks', '')}"

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
    rtkit \
    audio-config \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    "

# Mender packages (only for real hardware, not QEMU or RPi)
IMAGE_INSTALL:append = " \
    ${@'' if ('qemuall' in d.getVar('MACHINEOVERRIDES').split(':') or 'rpi' in d.getVar('MACHINEOVERRIDES').split(':')) else 'mender-configure mender-connect'} \
    ${@'' if ('qemuall' in d.getVar('MACHINEOVERRIDES').split(':') or 'rpi' in d.getVar('MACHINEOVERRIDES').split(':')) else 'python3-pip-jetson-config'} \
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
IMAGE_ROOTFS_EXTRA_SPACE:append = "${@bb.utils.contains("DISTRO_FEATURES", "systemd", " + 4096", "", d)}"

# A space-separated list of variable names that BitBake prints in the
# "Build Configuration" banner at the start of a build.
BUILDCFG_VARS += " \
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
require ${@'conf/distro/include/rpi-nvme-image.inc' if 'raspberrypi5-nvme' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
