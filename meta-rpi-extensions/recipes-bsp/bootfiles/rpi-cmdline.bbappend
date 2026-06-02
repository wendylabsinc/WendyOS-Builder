inherit partuuid-rpi

# All Mender-enabled RPi machines (RPi3/4/5) let meta-mender-raspberrypi's
# rpi-cmdline.bbappend manage `root=` via ${mender_kernel_root} (U-Boot
# resolves it at boot to the active A/B slot). We only contribute WendyOS
# console + USB-gadget additions via :append:rpi.
#
# `modules-load=dwc2` is correct for every WendyOS RPi target that opts
# into USB gadget mode:
#   - RPi3 A+ (and Zero 2 W / CM3+): BCM283x dwc2 peripheral controller.
#   - RPi4:                          BCM2711 dwc2 controller (USB-C OTG).
#   - RPi5:                          BCM2712 has its own dwc2 IP block at
#                                    /sys/class/udc/1000480000.usb, wired
#                                    to the USB-C port. This is separate
#                                    from the RP1 southbridge's xHCI host
#                                    controllers driving the USB-A ports.
# A separate BCM2712-specific patch in this layer
# (0001-dwc2-force-g_dma-false-for-BCM2712-in-peripheral-mod.patch) forces
# PIO mode so gadget DMA actually works on RPi5.
#
# RPi3 B/B+ has WENDYOS_USB_GADGET=0 (LAN9514 hub blocks dwc2 peripheral
# mode), so the modules-load clause is inert there.
#
# A hypothetical future RPi without a dwc2 peripheral controller would
# need its own :append:<machine> override.
WENDYOS_RPI_CMDLINE_EXTRAS = " console=serial0,115200${@' modules-load=dwc2' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"
CMDLINE_ROOTFS:append:rpi = "${WENDYOS_RPI_CMDLINE_EXTRAS}"

do_deploy[depends] += "${PN}:do_generate_partuuids"
