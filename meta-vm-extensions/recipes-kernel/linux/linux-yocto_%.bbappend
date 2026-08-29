# Point the arm64 VM machine at the BSP definition it wraps.
#
# kernel-yocto.bbclass defaults KMACHINE to ${MACHINE}, and do_kernel_metadata
# resolves it by searching yocto-kernel-cache for an .scc that declares
# `define KMACHINE <value>` (bsp/genericarm64/genericarm64-standard.scc declares
# "genericarm64"). Nothing declares "vm-arm64-wendyos", so without this the build
# fails with "Could not locate BSP definition for vm-arm64-wendyos/standard and
# no defconfig was provided".
#
# The x86_64 VM machine needs no equivalent: meta-yocto-bsp's linux-yocto append
# sets KMACHINE:genericx86-64 = "common-pc-64" under an override this machine
# carries. That same append has no KMACHINE:genericarm64 -- the real genericarm64
# machine gets the right value only because its MACHINE and KMACHINE are the same
# string, which is not true here.
KMACHINE:vm-arm64-wendyos = "genericarm64"

# Deliberately NO COMPATIBLE_MACHINE:append. base.bbclass checks it with
# re.match against each MACHINEOVERRIDES token, not re.search against MACHINE, and
# both VM machines put their BSP's name into MACHINEOVERRIDES themselves -- so the
# BSP's own COMPATIBLE_MACHINE:<bsp> = "<bsp>" already matches.
#
# Deliberately NO virtio kernel fragment. genericarm64.scc includes cfg/virtio.scc
# (VIRTIO/_PCI/_MMIO/_BLK/_NET/_CONSOLE/HW_RANDOM_VIRTIO all =y) plus boot-live,
# usb-mass-storage, efi-ext and kubernetes for vfat/NLS/GPT/ext4. Everything an
# initramfs-less VM needs to reach root=PARTLABEL= is already built in. Verified
# against yocto-kernel-cache branch yocto-6.18.
