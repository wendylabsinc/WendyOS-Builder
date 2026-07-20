FILESEXTRAPATHS:prepend := "${THISDIR}/tegra-flash-init:"

# Recovery installer identity handshake: the host reads device.json from the
# first, non-destructive flashpkg LUN and rejects a wrong module/carrier before
# it hands over QSPI/rootfs programming commands.
SRC_URI += "file://0001-flash-init-export-device-identity.patch"

# macOS release signal: a Mac host can only eject the LUN medium (diskutil
# eject), not the SCSI power-off Linux's udisksctl sends. Accept an emptied
# removable-LUN backing file as "host done with this LUN" so the installer
# advances past each LUN on macOS as well as Linux.
SRC_URI += "file://0002-flash-init-accept-medium-eject-release.patch"

# Windows enumeration: Windows fails GET_DESCRIPTOR(DEVICE) on the flashing
# gadget with XACT_ERROR/INVALID_PARAMETER on EP0 (usbstor never binds; the
# flash stalls waiting for the LUN), while Linux/macOS enumerate the identical
# gadget cleanly — so it is a Windows-xHCI/tegra-xudc EP0 quirk, not descriptor
# content (bcdUSB is not the cause). WendyOS's runtime IAD composite gadget
# (bDeviceClass 0xEF, NCM+ACM) enumerates on the same Windows host, so present
# the flashing gadget the same way: an IAD composite (0xEF) with a CDC-ACM
# function beside mass storage. init-flash.sh still drives the mass_storage LUN
# unchanged; only the enumeration shape changes.
SRC_URI += "file://0003-flash-init-composite-gadget-for-windows.patch"
