# WendyOS VM layer set.
#
# meta-yocto-bsp provides the upstream genericx86-64 reference BSP that the VM
# machine wraps. meta-vm-extensions carries the VM-only boot layer (A/B wks, the
# GRUB config and its module bbappend, the OTA connector pin) and is layered only
# here, so it never reaches a hardware board.
#
# Deliberately NOT layered: meta-x86-extensions (the VM is isolated from the PC
# board by design) and meta-security/ meta-tpm (the VM defaults to unencrypted /data;
# add it together with WENDYOS_DATA_ENCRYPTED = "1").

BBLAYERS += " \
    ${TOPDIR}/../repos/${WENDYOS_LAYER_TREE}/meta-yocto/meta-yocto-bsp \
    ${TOPDIR}/../${WENDYOS_META_REPO}/meta-vm-extensions \
    "

