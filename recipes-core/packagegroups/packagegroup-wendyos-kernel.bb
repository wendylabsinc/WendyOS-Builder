
PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

SUMMARY:${PN} = "Kernel package group"
RDEPENDS:${PN} = " \
    "

# Each game-controller symbol is requested as built-in or module by the shared
# kernel fragment. RRECOMMENDS is deliberate: Yocto emits no module package
# when a BSP resolves a symbol to =y, while it installs the package whenever
# the effective config resolves to =m. CI checks that outcome against the image
# manifest for every shipping machine. QEMU is outside this hardware contract
# and its linux-yocto recipe deliberately does not receive the fragment.
WENDYOS_GAME_CONTROLLER_ENABLE ?= "1"
WENDYOS_GAME_CONTROLLER_ENABLE:qemuall = "0"
WENDYOS_GAME_CONTROLLER_MODULE_PACKAGES = " \
    kernel-module-evdev \
    kernel-module-joydev \
    kernel-module-hid \
    kernel-module-hid-generic \
    kernel-module-usbhid \
    kernel-module-uhid \
    kernel-module-hidp \
    kernel-module-xpad \
    kernel-module-hid-microsoft \
    "

RRECOMMENDS:${PN}:append = "${@' ' + d.getVar('WENDYOS_GAME_CONTROLLER_MODULE_PACKAGES') if d.getVar('WENDYOS_GAME_CONTROLLER_ENABLE') == '1' else ''}"

# Mainline Bluetooth contract (wendy-bluetooth.inc): same RRECOMMENDS
# rationale as above — a package exists only where the effective config
# resolved =m, and CI cross-checks the outcome. Opt-in per machine, matching
# the kernel-side WENDYOS_BLUETOOTH_ENABLE gating; first adopter is the Orin
# Nano devkit (both storage machines share the jetson-orin-nano-devkit
# override).
WENDYOS_BLUETOOTH_ENABLE ?= "0"
WENDYOS_BLUETOOTH_ENABLE:jetson-orin-nano-devkit = "1"
WENDYOS_BLUETOOTH_MODULE_PACKAGES = " \
    kernel-module-bluetooth \
    kernel-module-btusb \
    kernel-module-btrtl \
    kernel-module-rfcomm \
    "

RRECOMMENDS:${PN}:append = "${@' ' + d.getVar('WENDYOS_BLUETOOTH_MODULE_PACKAGES') if d.getVar('WENDYOS_BLUETOOTH_ENABLE') == '1' else ''}"
