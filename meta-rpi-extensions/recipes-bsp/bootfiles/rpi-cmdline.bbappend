inherit partuuid-rpi

# RPi3 (MBR-partitioned card): the kernel reports MBR PARTUUIDs as
# <disksig>-<partno>, not as the UUIDv4 we generate, so reference root
# by its filesystem label (set in wic/rpi-mbr.wks).
#
# Override is pinned to :raspberrypi3-64 (not :raspberrypi3) on purpose:
# MACHINEOVERRIDES "raspberrypi3:rpi:raspberrypi3-64:..." has rightmost
# match winning, so :raspberrypi3-64 sits after :rpi defaults.
CMDLINE_ROOT_PARTITION:raspberrypi3-64 = "LABEL=root"
CMDLINE_ROOTFS:raspberrypi3-64 = "console=serial0,115200 root=${CMDLINE_ROOT_PARTITION} rootfstype=ext4 fsck.repair=yes rootwait"

# RPi4 and RPi5 use Mender's U-Boot path. The bbappend in
# meta-mender-raspberrypi/recipes-bsp/bootfiles/rpi-cmdline.bbappend
# conditionally includes rpi-cmdline-mender.inc, which removes the
# upstream "root=/dev/mmcblk0p2" default and appends
# "root=${mender_kernel_root}" — U-Boot resolves that at boot to the
# active A/B slot. We only contribute the WendyOS console + USB-gadget
# additions so two `root=` arguments don't end up on the cmdline.
WENDYOS_RPI_CMDLINE_EXTRAS = " console=serial0,115200${@' modules-load=dwc2' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"
CMDLINE_ROOTFS:append:raspberrypi4-64 = "${WENDYOS_RPI_CMDLINE_EXTRAS}"
# raspberrypi5-nvme inherits the :raspberrypi5 append via MACHINEOVERRIDES
# (=. "rpi:raspberrypi5-nvme:raspberrypi5:") — no separate :raspberrypi5-nvme
# entry needed (and adding one would double the extras on the cmdline).
CMDLINE_ROOTFS:append:raspberrypi5 = "${WENDYOS_RPI_CMDLINE_EXTRAS}"

do_deploy[depends] += "${PN}:do_generate_partuuids"
