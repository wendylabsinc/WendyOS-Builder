FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:x86-wendyos = " \
    file://x86-nuc-drivers.cfg \
    file://0001-wifi-mt76-mt7921e-add-MT7920-PCI-support.patch \
    "
