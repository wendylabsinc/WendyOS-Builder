# Tegra-specific packagegroup-wendyos-base configuration
# This file is included when building for Tegra machines

# Tegra-specific tools and hardware support.
# tegra-flash-reboot ships only on scarthgap meta-tegra (Orin / tegra234);
# r38.4.x meta-tegra (Thor / tegra264) has no such recipe, so gate it.
RDEPENDS:${PN}:append = " \
    efibootmgr \
    ${@'tegra-flash-reboot' if 'tegra234' in d.getVar('MACHINEOVERRIDES').split(':') else ''} \
    tegra-tools-tegrastats \
    "
