FILESEXTRAPATHS:prepend := "${THISDIR}/tegra-flash-init:"

# Recovery installer identity handshake: the host reads device.json from the
# first, non-destructive flashpkg LUN and rejects a wrong module/carrier before
# it hands over QSPI/rootfs programming commands.
SRC_URI += "file://0001-flash-init-export-device-identity.patch"
