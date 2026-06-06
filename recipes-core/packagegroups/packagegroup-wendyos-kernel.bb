
PR = "r0"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

SUMMARY:${PN} = "Kernel package group"
RDEPENDS:${PN} = " \
    "

# Commodity x86 mini PCs and NUC-class systems vary widely in network
# hardware. Keep these as recommendations so images still build if a kernel
# provider does not emit one of the optional module packages.
RRECOMMENDS:${PN}:append:x86-wendyos = " \
    kernel-module-iwlwifi \
    kernel-module-iwlmvm \
    kernel-module-iwldvm \
    kernel-module-rtw88 \
    kernel-module-rtw88-pci \
    kernel-module-rtw88-usb \
    kernel-module-rtw89 \
    kernel-module-rtw89-pci \
    kernel-module-mt76 \
    kernel-module-mt7921e \
    kernel-module-mt7921u \
    kernel-module-mt7925-common \
    kernel-module-mt7925e \
    kernel-module-ath10k-pci \
    kernel-module-ath11k-pci \
    kernel-module-btusb \
    kernel-module-btintel \
    kernel-module-btrtl \
    kernel-module-btbcm \
    kernel-module-btmtk \
    kernel-module-e1000e \
    kernel-module-igb \
    kernel-module-igc \
    kernel-module-r8169 \
    kernel-module-r8152 \
    kernel-module-ax88179-178a \
    kernel-module-cdc-ether \
    kernel-module-amdgpu \
    kernel-module-radeon \
    kernel-module-nouveau \
    kernel-module-thunderbolt \
    kernel-module-thunderbolt-net \
    kernel-module-typec \
    kernel-module-typec-ucsi \
    kernel-module-ucsi-acpi \
    kernel-module-roles \
    "
