SUMMARY = "Audio, Bluetooth and Camera Configuration for WendyOS"
DESCRIPTION = "Configures the system-wide PipeWire graph so audio, Bluetooth and cameras work out of the box on a headless device"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

SRC_URI = " \
    file://95-pipewire.preset \
    file://60-wireplumber-camera-headless.conf \
    file://wireplumber-bluetooth.conf \
    file://wireplumber-state.conf \
"

S = "${UNPACKDIR}"

do_install() {
    # Systemd preset that enables WirePlumber next to the system-wide PipeWire
    # daemon. PipeWire alone publishes nothing — the session manager is what
    # turns hardware into nodes.
    install -d ${D}${systemd_unitdir}/system-preset
    install -m 0644 ${UNPACKDIR}/95-pipewire.preset ${D}${systemd_unitdir}/system-preset/

    # Install WirePlumber configuration that makes a missing V4L2 monitor fatal
    install -d ${D}${sysconfdir}/wireplumber/wireplumber.conf.d
    install -m 0644 ${UNPACKDIR}/60-wireplumber-camera-headless.conf \
        ${D}${sysconfdir}/wireplumber/wireplumber.conf.d/

    # Install D-Bus policy for Bluetooth access
    # Allows the pipewire user to communicate with BlueZ over D-Bus
    install -d ${D}${sysconfdir}/dbus-1/system.d
    install -m 0644 ${UNPACKDIR}/wireplumber-bluetooth.conf \
        ${D}${sysconfdir}/dbus-1/system.d/

    # Give WirePlumber a writable state directory (it has no home)
    install -d ${D}${systemd_system_unitdir}/wireplumber.service.d
    install -m 0644 ${UNPACKDIR}/wireplumber-state.conf \
        ${D}${systemd_system_unitdir}/wireplumber.service.d/state.conf
}

FILES:${PN} += " \
    ${systemd_unitdir}/system-preset/95-pipewire.preset \
    ${sysconfdir}/wireplumber/wireplumber.conf.d/60-wireplumber-camera-headless.conf \
    ${sysconfdir}/dbus-1/system.d/wireplumber-bluetooth.conf \
    ${systemd_system_unitdir}/wireplumber.service.d/state.conf \
"

# Runtime dependencies
RDEPENDS:${PN} = " \
    pipewire \
    pipewire-v4l2 \
    wireplumber \
    pipewire-pulse \
    pipewire-alsa \
    pipewire-spa-plugins-v4l2 \
    pipewire-spa-plugins-libcamera \
    pipewire-spa-tools \
    pipewire-tools \
    bluez5 \
    bluez5-obex \
    dbus \
    alsa-utils \
    alsa-plugins \
    alsa-lib \
"

# rtkit provides real-time priority for audio, but requires polkit
# Add it if polkit is enabled in distro features
RDEPENDS:${PN} += "${@bb.utils.contains('DISTRO_FEATURES', 'polkit', 'rtkit', '', d)}"
