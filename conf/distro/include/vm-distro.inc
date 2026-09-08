# WendyOS VM distro configuration.
# Required from wendyos.conf when MACHINEOVERRIDES contains "vm-wendyos".

# No firmware-update, USB-gadget, GPU or CAN story in a VM.
# These are read by nothing on the VM path, but they are in BUILDCFG_VARS, so
# setting them keeps the build banner truthful. WENDYOS_EFI_DEBUG is deliberately
# NOT set: it is Tegra-only and not in BUILDCFG_VARS, so a value here would be
# dead text.
#
# BUILDCFG_VARS lives in conf/distro/wendyos.conf, not wendyos-image.bb. It is
# read from the config datastore at BuildStarted, so a recipe-scope append never
# reached the banner -- for a long time this list printed nothing at all.
#
# These "?=" lines do fire. wendyos.conf declares its base defaults with "??=", a
# weak default that a later "?=" overrides, so the per-family value set here wins
# while a machine conf or local.conf still wins over both. That was not always
# true: while those defaults were "?=" they landed first and made
# WENDYOS_UPDATE_BOOTLOADER below dead, so the VM resolved to "1" -- the exact
# thing the comment above says it is here to prevent.
WENDYOS_UPDATE_BOOTLOADER ?= "0"
WENDYOS_USB_GADGET ?= "0"
WENDYOS_DEEPSTREAM ?= "0"
WENDYOS_NVIDIA_DGPU ?= "0"
WENDYOS_CAN ?= "0"

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

