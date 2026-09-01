# WendyOS VM distro configuration.
# Required from wendyos.conf when MACHINEOVERRIDES contains "vm-wendyos".

# No firmware-update, USB-gadget or GPU story in a VM.
# These four are read by nothing on the VM path, but all four are in
# wendyos-image.bb's BUILDCFG_VARS, so setting them keeps the build banner
# truthful (the distro otherwise defaults WENDYOS_UPDATE_BOOTLOADER to "1", which
# would be a lie for a VM). WENDYOS_EFI_DEBUG is deliberately NOT set: it is
# Tegra-only and is not even in BUILDCFG_VARS, so a value here would be dead text.
WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_USB_GADGET ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
WENDYOS_NVIDIA_DGPU ?= "0"

# The VM is discovered over the host network, not a direct USB gadget link, so
# do not restrict Avahi to usb0.
WENDYOS_MDNS_INTERFACES ?= ""

# /data encryption seals the LUKS2 keyslot to a TPM, and a plain VM has none.
# Turning this on means providing a virtual TPM to the guest (swtpm on the QEMU
# path, or UTM's TPM 2.0 device on the Apple path) and layering meta-tpm. 
# wendyos-image.bb hard-fails if this is "1" while WENDYOS_ENABLE_TPM is "0", 
# so the two must move together.
WENDYOS_DATA_ENCRYPTED ?= "0"

# wifi and bluetooth are NOT set here, and deliberately not removed either.
# Both are poky DISTRO_FEATURES_DEFAULTS (oe-core default-distrovars.inc) and
# wendyos.conf removes only x11/wayland/sysvinit/ptest/3g, so they are on either
# way. x86-distro.inc appends them explicitly, which is a no-op for the same reason.
#
# Keeping them is what the VM wants. The agent drives Bluetooth over D-Bus to
# org.bluez -- verified in the shipped binary (org.bluez.Adapter1.StartDiscovery,
# AgentManager1.RegisterAgent, Device1.Connect; no bluetoothctl anywhere). Without
# bluez5 in the image the agent gets a D-Bus "service unknown" instead of the clean
# "no adapter" a radio-less real device would report -- a parity difference, not a
# saving. MACHINE_FEATURES in the machine conf carries the matching half.

