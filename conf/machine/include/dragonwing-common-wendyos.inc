# Common WendyOS settings for the Qualcomm Dragonwing EVKs.
# Required after the upstream iq-<soc>-evk.conf include in each machine conf, so
# these plain assignments win over meta-qcom's defaults.

# wendyos-update A/B OTA stack. Pulls in the update client, the fixed rootfs-size
# pin (image == slot == .wendy payload) and the .wendy artifact, plus
# wendyos-etc-binds so device identity persists on /data across a slot switch.
WENDYOS_OTA = "wendy"

# --- A/B boot chain ---------------------------------------------------------
# ROM -> XBL -> the SoC's own UEFI -> GRUB on the ESP -> kernel from the selected
# ext4 slot. GRUB rather than the vendor's systemd-boot because systemd-boot reads
# only FAT (ESP/XBOOTLDR) and so cannot reach the kernel that ships inside each
# rootfs slot; after an OTA the new rootfs would boot the stale ESP kernel. GRUB's
# ext2 module reads ext4, so /boot/Image travels with the rootfs and an OTA stays
# a single raw partition write.
#
# EFI_PROVIDER must be set here, not in the ESP image recipe: grub-efi's own
# anonymous python reads it to decide its output name, emitting bootaa64.efi only
# when it is "grub-efi" (upstream qcom-common.inc sets systemd-boot, which would
# make it grub-efi-bootaa64.efi and leave the firmware with nothing to chainload
# at EFI/BOOT/BOOTAA64.EFI).
EFI_PROVIDER = "grub-efi"

# Our ESP (GRUB + grub.cfg + grubenv) instead of upstream's systemd-boot + UKI one.
QCOM_ESP_IMAGE = "wendyos-esp-image"

# grub-efi RDEPENDS on virtual-grub-bootconf; both oe-core's grub-bootconf and our
# wendyos-grub-ab provide it and ship ${EFI_FILES_PATH}/grub.cfg, so the choice has
# to be explicit or dnf fails the image transaction on a file conflict.
PREFERRED_RPROVIDER_virtual-grub-bootconf = "wendyos-grub-ab"

# Our A/B partition layout instead of upstream's pre-generated single-rootfs one.
# Declares LUN 0 only, so a flash cannot rewrite the XBL/UEFI/TZ firmware LUNs --
# the board stays recoverable by construction.
QCOM_PARTITION_CONF = "wendyos-partition-conf"
QCOM_PARTITION_FILES_SUBDIR = "partitions/${MACHINE}/ufs"

# The kernel gets root= from grub.cfg per slot, so the single-rootfs default
# (PARTLABEL=rootfs) must not be baked anywhere. Point it at slot A so any
# upstream consumer that still reads it lands on a real partition rather than a
# label that no longer exists in our layout.
QCOM_BOOTIMG_ROOTFS = "PARTLABEL=rootfsA"

# No UEFI capsule work from our side: the board's own firmware owns the capsule
# path (it pre-allocates /boot/Persisted_Capsules.bin), and we do not write
# firmware partitions.
WENDYOS_UPDATE_BOOTLOADER = "0"
WENDYOS_EFI_DEBUG = "0"

# NVIDIA-only stacks.
WENDYOS_DEEPSTREAM = "0"

# More than one dwc3 controller is dual-role and registers a UDC, and the one the
# gadget wants does not sort first, so the controller has to be named explicitly.
# The Tegra-only gadget helper recipes that wendyos-image.bb pairs with this
# setting are dropped in conf/distro/include/qcom-image.inc, exactly as the RPi
# include does.
WENDYOS_USB_GADGET = "1"
WENDYOS_USB_UDC = "a600000.usb"

# /data encryption stays off: turning it on is a separate decision with its own
# rollback hazard, and not every board here has usable TPM firmware to enroll to.
WENDYOS_DATA_ENCRYPTED = "0"
WENDYOS_ENABLE_TPM = "0"

# Qualcomm AI stack for the on-SoC Hexagon NPU, installed into the image. The device has
# no package manager, so it cannot be added afterwards.
#
# "0" drops only qairt-sdk and fastrpc-tests: meta-qcom recommends the DSP userspace and
# the HTP skels regardless, and the skels are a qairt-sdk subpackage.
WENDYOS_QCOM_NPU ?= "1"
