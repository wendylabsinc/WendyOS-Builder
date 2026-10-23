# Pi and Jetson kernels can leave a second rejected LE connection in
# BT_CONNECT. Share the upstream fix across those vendor kernels. The Qualcomm
# kernel (Dragonwing, Arduino) already carries it.
FILESEXTRAPATHS:prepend := "${THISDIR}/bluetooth-le-pending:"
BLUETOOTH_LE_PENDING_PATCH ?= "0001-bluetooth-clean-up-rejected-pending-le-connection.patch"
SRC_URI += "file://${BLUETOOTH_LE_PENDING_PATCH}"
