# Qualcomm Dragonwing distro configuration.
# Required from wendyos.conf when MACHINEOVERRIDES contains 'qcom-wendyos'.

WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_EFI_DEBUG ?= "0"
WENDYOS_DEEPSTREAM ?= "0"


# Discovered over LAN as well as usb0 -- this is a devkit on an Ethernet drop,
# not a headless product behind a single USB cable.
WENDYOS_MDNS_INTERFACES ?= ""

# Onboard PCIe Wi-Fi (QCNFA765) plus Bluetooth; both are in the upstream
# MACHINE_FEATURES.
DISTRO_FEATURES:append = " wifi bluetooth"
