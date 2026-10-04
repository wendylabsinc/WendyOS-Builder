
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
# allow-empty-password and allow-root-login (the individual features behind the
# legacy `debug-tweaks` alias, which wrynose oe-core removed from
# IMAGE_FEATURES[validitems]). Those root/empty-password features
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
#       cmdline, which is NOT the serial port everywhere, as this comment
#       used to claim. Measured on jetson-agx-orin 2026-10-04: Tegra and x86
#       both end their cmdline console=tty0, so /dev/console is the VT on
#       both. Grouped per board via WENDYOS_CONSOLE_LOGIN_TYPE so the
#       operator's UART/VT choice governs the login they actually get.
#       That grouping is harmless rather than load-bearing on the boards with
#       a real UART login, because Tegra and RPi both set SERIAL_CONSOLES
#       (meta-tegra tegra234.inc:9 ttyTCU0 and tegra264.inc:13 ttyUTC0; ttyS0
#       on rpi3/rpi4 and ttyAMA0 on rpi5), so their serial login comes from
#       serial-getty@ and not from console-getty. RPi's own /dev/console was
#       not measured.
#       The same fact is why a recovery key written to /dev/console on a
#       Jetson reaches nobody -- see C75 in
#       docs/plans/configurable-data-encryption.md.
#
# The kernel `console=` bootarg (boot + printk output, not a getty) is separate:
# on RPi it is gated on WENDYOS_DEBUG_UART (rpi-cmdline.bbappend); Tegra emits it
# regardless (task A2). Independent of the login knobs here.
#
# Masking is fatal: systemd's 90-systemd.preset enables getty@/serial-getty@ and
# the rootfs preset-all pass rejects "enable a masked unit". So preset-disable
# (a 10- file beats 90-) + drop any enablement symlinks; VT additionally zeroes
# logind's auto-VTs (stops the autovt@ VT-switch spawns a preset can't reach).

# console-getty logs in on /dev/console, whose identity is board-specific and
# is NOT always the UART: Qualcomm boots console=ttyMSM0 alone so it really is
# the serial port, while Tegra and x86 both end their cmdline console=tty0 and
# so land on the VT (measured 2026-10-04). Tegra is grouped with UART anyway
# because its real serial login is serial-getty@ from SERIAL_CONSOLES, and the
# operator's UART choice should govern both together.
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

# wendyos-data.service orders itself around two systemd instance units whose
# names it spells out in full, systemd-fsck@dev-wendyos-data.service and
# blockdev@dev-wendyos-data.target. Both names are derived from the /data
# device path. Change the path and the names stop matching anything, the boot
# ordering quietly turns into a no-op and nothing reports it -- systemd has no
# complaint about ordering against a unit nobody ever instantiates.
#
# Neither instance exists until systemd builds it at boot, so a build-time
# check can only compare strings. That is the whole point: the drift being
# guarded against is a drift of the string.
#
# Finding the path is option A, reading it back out of the finished rootfs from
# the two places that decide it. fstab carries a /data line on x86, VM and every
# RPi. data.mount is the only source on Tegra and Qualcomm, which have no /data
# fstab line at all -- rpi-image.inc:66, x86-image.inc:78 and vm-image.inc:78
# remove the data-mount package, the other two keep it. No board has both, so
# two answers that disagree are a defect rather than a board variant.
check_data_ordering() {
    data_fstab="${IMAGE_ROOTFS}${sysconfdir}/fstab"
    data_unit="${IMAGE_ROOTFS}${systemd_system_unitdir}/data.mount"
    data_service="${IMAGE_ROOTFS}${systemd_system_unitdir}/wendyos-data.service"

    # awk for every read below, never grep. do_rootfs runs under `set -e` and
    # grep exits 1 when it selects nothing, so an ordinary "no match" would
    # kill the task before this function could say anything useful. awk exits 0
    # either way and the caller decides what the empty answer means.
    data_fstab_dev=""
    if [ -f "$data_fstab" ]; then
        data_fstab_dev=$(awk '
            { line = $0; sub(/^[ \t]+/, "", line) }
            line ~ /^#/ { next }
            $2 == "/data" { print $1 }
        ' "$data_fstab")
    fi

    data_unit_dev=""
    if [ -f "$data_unit" ]; then
        data_unit_dev=$(awk '
            { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
            line ~ /^[#;]/ { next }
            line ~ /^What[ \t]*=/ { sub(/^What[ \t]*=[ \t]*/, "", line); print line }
        ' "$data_unit")
    fi

    if [ -z "$data_fstab_dev" ] && [ -z "$data_unit_dev" ]; then
        bbfatal "check_data_ordering: found no /data device path in the image." \
                "Looked for a line with mount point /data in $data_fstab and for What= in $data_unit; neither file gave one."
    fi
    if [ -n "$data_fstab_dev" ] && [ -n "$data_unit_dev" ] && [ "$data_fstab_dev" != "$data_unit_dev" ]; then
        bbfatal "check_data_ordering: the two /data device paths disagree." \
                "$data_fstab says '$data_fstab_dev', $data_unit says '$data_unit_dev'." \
                "No board should carry both, so one of them is wrong."
    fi
    if [ -n "$data_fstab_dev" ]; then
        data_dev="$data_fstab_dev"
        data_src="$data_fstab"
    else
        data_dev="$data_unit_dev"
        data_src="$data_unit"
    fi

    # Derive the instance name the way systemd does: drop the leading slash,
    # turn every other slash into a dash. systemd-escape is a target binary and
    # is not on the build host, so this is done by hand -- and the plain rule
    # only holds while the path carries nothing that needs hex escaping. Refuse
    # anything outside that set instead of guessing. A name that looks right and
    # matches no unit is the exact failure this guard exists to catch, so
    # producing one here would defeat the check.
    case "$data_dev" in
        /*) ;;
        *) bbfatal "check_data_ordering: '$data_dev' (from $data_src) is not an absolute path, so no systemd instance name can be derived from it." ;;
    esac
    case "$data_dev" in
        *[!A-Za-z0-9:_./]*) bbfatal "check_data_ordering: '$data_dev' (from $data_src) holds a character outside [A-Za-z0-9:_./]. systemd would hex-escape it and this check cannot." ;;
    esac
    case "$data_dev" in
        */) bbfatal "check_data_ordering: '$data_dev' (from $data_src) ends in a slash." ;;
        *//*) bbfatal "check_data_ordering: '$data_dev' (from $data_src) has an empty path component." ;;
        */.*) bbfatal "check_data_ordering: '$data_dev' (from $data_src) has a component starting with a dot. systemd would hex-escape it and this check cannot." ;;
    esac
    data_esc=$(printf '%s' "${data_dev#/}" | tr '/' '-')

    # data-device is fleet-wide through packagegroup-wendyos-base.bb:35, so a
    # missing unit is a broken image, not a board that happens to have no /data.
    if [ ! -f "$data_service" ]; then
        bbfatal "check_data_ordering: $data_service is missing, but data-device ships on every board."
    fi
    data_missing=$(awk -v a="Before=systemd-fsck@$data_esc.service" \
                       -v b="Wants=blockdev@$data_esc.target" \
                       -v c="Before=blockdev@$data_esc.target" '
        { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
        line ~ /^[#;]/ { next }
        line == a { got_a = 1 }
        line == b { got_b = 1 }
        line == c { got_c = 1 }
        END {
            if (!got_a) printf "%s ", a
            if (!got_b) printf "%s ", b
            if (!got_c) printf "%s ", c
        }
    ' "$data_service")
    if [ -n "$data_missing" ]; then
        bbfatal "check_data_ordering: $data_service does not order itself around the /data device it prepares." \
                "The device is '$data_dev' (from $data_src), which escapes to '$data_esc', so these lines are missing: $data_missing"
    fi

    # The consumer half of the blockdev@ ordering, checked only where the image
    # ships its own data.mount. systemd adds that dependency to every mount by
    # itself, but re-derives it from the device the kernel resolved as soon as
    # /data is mounted, so the instance stops being the one the service names
    # (systemd mount.c:567). Only a line in the unit file survives that, which
    # is why systemd-fstab-generator writes this same line into the mounts it
    # generates (generator.c:889). On the boards whose data.mount is generated
    # there is no build-time artifact to read, so the check says nothing for
    # them.
    if [ -f "$data_unit" ]; then
        data_unit_want="After=blockdev@$data_esc.target"
        data_unit_got=$(awk -v a="$data_unit_want" '
            { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
            line ~ /^[#;]/ { next }
            line == a { print "yes"; exit }
        ' "$data_unit")
        if [ -z "$data_unit_got" ]; then
            bbfatal "check_data_ordering: $data_unit does not order itself after the /data blockdev target." \
                    "The device is '$data_dev' (from $data_src), which escapes to '$data_esc', so this line is missing: $data_unit_want"
        fi
    fi

    # Nothing else may wait on the .device unit. On an encrypted board
    # /dev/wendyos/data IS the unlocked mapper that wendyos-data.service
    # produces, so any other unit that runs before the mount and waits on
    # dev-wendyos-data.device blocks the service that would create it. Only two
    # files are allowed to name it: data.mount, the consumer the alias exists
    # for, and rpi3's 10-device-mbr.conf, which is safe because that board can
    # never encrypt (C21) and its alias always points at the raw partition.
    #
    # The search is fixed-string on purpose. blockdev@dev-wendyos-data.target
    # and systemd-fsck@dev-wendyos-data.service do not contain the substring
    # "dev-wendyos-data.device", so they cannot be caught here -- a regex loose
    # enough to match them would flag the very lines the check above demands.
    # find -type f also keeps the .wants symlinks out, so enabling a unit does
    # not count as a second reference to it.
    set -- "${IMAGE_ROOTFS}${systemd_system_unitdir}"
    if [ -d "${IMAGE_ROOTFS}${sysconfdir}/systemd/system" ]; then
        set -- "$@" "${IMAGE_ROOTFS}${sysconfdir}/systemd/system"
    fi
    data_strays=$(find "$@" -type f -exec awk -v s="$data_esc.device" '
        { line = $0; sub(/^[ \t]+/, "", line) }
        line ~ /^[#;]/ { next }
        index($0, s) && !seen[FILENAME]++ {
            if (FILENAME !~ /\/data\.mount$/ && FILENAME !~ /\/wendyos-data\.service\.d\/10-device-mbr\.conf$/)
                printf "%s ", FILENAME
        }
    ' {} +)
    if [ -n "$data_strays" ]; then
        bbfatal "check_data_ordering: $data_esc.device is named outside data.mount and the rpi3 drop-in, by: $data_strays" \
                "On an encrypted board wendyos-data.service is what creates that device, so anything else waiting on it before the mount cannot be satisfied."
    fi
}

ROOTFS_POSTPROCESS_COMMAND += "check_data_ordering;"

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
require ${@'conf/distro/include/vm-image.inc' if 'vm-wendyos' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
require ${@'conf/distro/include/qcom-image.inc' if 'qcom-wendyos' in d.getVar('MACHINEOVERRIDES').split(':') else ''}

# Config sanity check. Encrypting /data needs a TPM at runtime -- the /data
# resolver seals the LUKS2 keyslot to it -- so WENDYOS_DATA_ENCRYPTED turns
# WENDYOS_ENABLE_TPM on in the per-board local includes. Writing the two to
# contradictory values by hand would build an image whose conversion can never
# succeed, and the failure would only show up on the device. Catch it at parse
# time instead.
# Boards that set neither variable (RPi) leave both unset and are unaffected.
python () {
    if d.getVar('WENDYOS_DATA_ENCRYPTED') == '1' and d.getVar('WENDYOS_ENABLE_TPM') != '1':
        bb.fatal('WENDYOS_DATA_ENCRYPTED = "1" requires WENDYOS_ENABLE_TPM = "1": '
                 '/data encryption seals the LUKS2 keyslot to the TPM. Either drop '
                 'the explicit WENDYOS_ENABLE_TPM = "0" from local.conf (the '
                 'per-board include turns it on automatically), or set '
                 'WENDYOS_DATA_ENCRYPTED = "0" for a plain-ext4 /data.')
}
