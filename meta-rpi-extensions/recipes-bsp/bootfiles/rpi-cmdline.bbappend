inherit partuuid-rpi

# `root=` is set at boot by the A/B boot script (boot-ab.cmd, rpi-u-boot-scr)
# from the selected slot. We only contribute WendyOS console + USB-gadget
# additions via :append:rpi.
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
#
# `console=serial0,115200` (the kernel bootarg that puts boot + printk output
# on UART) is gated on WENDYOS_DEBUG_UART, mirroring WENDYOS_ENABLE_UART_LOGIN's
# gate on the serial *login* prompt (see wendyos-image.bb's disable_uart_login).
# Fortress default (WENDYOS_DEBUG_UART="0"): no serial console registered, so
# neither boot logs nor a login prompt reach UART. Dev/PR builds
# (WENDYOS_DEBUG_UART="1", set by CI) restore the console= arg so field
# bring-up can watch the boot again. "serial0" is the RPi firmware alias that
# resolves to the correct UART per board (ttyAMA0 on RPi5, ttyS0 on RPi3/4 —
# see SERIAL_CONSOLES above), so no per-machine override is needed here.
WENDYOS_RPI_CMDLINE_EXTRAS = "${@' console=serial0,115200' if d.getVar('WENDYOS_DEBUG_UART') == '1' else ''}${@' modules-load=dwc2' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"
CMDLINE_ROOTFS:append:rpi = "${WENDYOS_RPI_CMDLINE_EXTRAS}"

do_deploy[depends] += "${PN}:do_generate_partuuids"
