
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Provide our custom /etc/hosts, profile.d defaults, console branding, and sysctl
SRC_URI += " \
    file://hosts \
    file://profile.d/wendyos-defaults.sh \
    file://issue \
    file://issue.net \
    file://sysctl.d/99-quiet-console.conf \
    "

do_install:append() {
    install -m 0644 ${UNPACKDIR}/hosts ${D}${sysconfdir}/hosts

    # Install profile.d defaults
    install -d ${D}${sysconfdir}/profile.d
    install -m 0755 ${UNPACKDIR}/profile.d/wendyos-defaults.sh ${D}${sysconfdir}/profile.d/wendyos-defaults.sh

    # Install console login branding (displayed before login prompt)
    install -m 0644 ${UNPACKDIR}/issue ${D}${sysconfdir}/issue
    install -m 0644 ${UNPACKDIR}/issue.net ${D}${sysconfdir}/issue.net

    # Install sysctl config to quiet console (reduce kernel/audit messages)
    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${UNPACKDIR}/sysctl.d/99-quiet-console.conf ${D}${sysconfdir}/sysctl.d/

    # Suppress the upstream Poky /etc/motd disclaimer.
    # Dynamic MOTD comes from update-motd via /etc/profile.d/motd.sh
    # (see recipes-core/wendyos-motd).
    : > ${D}${sysconfdir}/motd
}

# Make it a config file so local edits survive upgrades
CONFFILES:${PN} += "${sysconfdir}/hosts"

hostname:pn-base-files = "wendyos"

# RPi5-specific extensions — isolated so Tegra/QEMU builds are unaffected
require ${@'rpi-base-files.inc' if 'rpi' in d.getVar('MACHINEOVERRIDES').split(':') else ''}

# x86 A/B fstab — isolated so other boards are unaffected
require ${@'x86-base-files.inc' if 'x86-wendyos' in d.getVar('MACHINEOVERRIDES').split(':') else ''}
