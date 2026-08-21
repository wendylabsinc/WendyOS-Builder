FILESEXTRAPATHS:prepend := "${THISDIR}/linux-raspberrypi:"

# Add container support kernel config when WENDYOS_CONTAINER_RUNTIME is enabled
SRC_URI:append:rpi = "${@' file://container.cfg' if d.getVar('WENDYOS_CONTAINER_RUNTIME') == '1' else ''}"

# Add USB gadget kernel config when WENDYOS_USB_GADGET is enabled
SRC_URI:append:rpi = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"
SRC_URI += "file://0001-dwc2-force-g_dma-false-for-BCM2712-in-peripheral-mod.patch"

# Driver add-ons: the kernel prerequisites (sysext/module-sign fragments plus module
# signing). Isolated so the kernel is untouched on boards that ship no add-ons. The
# file is board-neutral and lives in the wendyos layer, which is on BBPATH, so any
# other board's kernel bbappend enables the same thing with this one line.
require ${@'recipes-kernel/linux/driver-extensions.inc' if d.getVar('WENDYOS_DRIVER_EXTENSIONS') == '1' else ''}

