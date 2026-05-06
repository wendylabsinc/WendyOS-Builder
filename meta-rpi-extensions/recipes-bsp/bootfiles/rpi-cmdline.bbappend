inherit partuuid-rpi

CMDLINE_ROOT_PARTITION:rpi = "PARTUUID=${WENDYOS_ROOT_PARTUUID}"
# RPi3 boots from an MBR-partitioned card; the kernel reports MBR PARTUUIDs as
# <disksig>-<partno>, not as the UUIDv4 we generate, so reference root by its
# filesystem label (set in wic/rpi-mbr.wks) instead.
#
# Override is pinned to :raspberrypi3-64 (not :raspberrypi3) on purpose: with
# MACHINEOVERRIDES "raspberrypi3:rpi:raspberrypi3-64:..." the rightmost match
# wins, so :raspberrypi3 would lose to :rpi above. :raspberrypi3-64 sits after
# :rpi and overrides it.
CMDLINE_ROOT_PARTITION:raspberrypi3-64 = "LABEL=root"
CMDLINE_ROOTFS:rpi = "console=serial0,115200 root=${CMDLINE_ROOT_PARTITION} rootfstype=ext4 fsck.repair=yes rootwait"
CMDLINE_ROOTFS:append:rpi = "${@' modules-load=dwc2' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"
do_deploy[depends] += "${PN}:do_generate_partuuids"
