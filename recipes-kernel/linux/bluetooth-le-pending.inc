# Both supported vendor kernels can leave a second rejected LE connection in
# BT_CONNECT. Share the upstream fix so Pi and Jetson do not diverge.
FILESEXTRAPATHS:prepend := "${THISDIR}/bluetooth-le-pending:"
SRC_URI += "file://0001-bluetooth-clean-up-rejected-pending-le-connection.patch"
