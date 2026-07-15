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
