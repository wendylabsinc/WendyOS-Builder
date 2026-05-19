inherit partuuid-rpi

# All Mender-enabled RPi machines (RPi3/4/5) let meta-mender-raspberrypi's
# rpi-cmdline.bbappend manage `root=` via ${mender_kernel_root} (U-Boot
# resolves it at boot to the active A/B slot). We only contribute WendyOS
# console + USB-gadget additions via :append:rpi, which fires once for any
# RPi machine — future RPi variants pick this up automatically without
# enumerating them here.
WENDYOS_RPI_CMDLINE_EXTRAS = " console=serial0,115200${@' modules-load=dwc2' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"
CMDLINE_ROOTFS:append:rpi = "${WENDYOS_RPI_CMDLINE_EXTRAS}"

do_deploy[depends] += "${PN}:do_generate_partuuids"
