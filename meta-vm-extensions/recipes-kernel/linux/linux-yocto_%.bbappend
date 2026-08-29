# Make linux-yocto build for the VM machines.
#
# The VM machines carry the "genericx86-64" MACHINEOVERRIDE so they inherit the
# upstream BSP wiring from meta-yocto-bsp's linux-yocto_6.18.bbappend
# (KMACHINE:genericx86-64 ?= "common-pc-64"). That same override also sets
# COMPATIBLE_MACHINE:genericx86-64 = "genericx86-64", which is re.search'd
# against MACHINE — it matches "genericx86-64-wendyos" as a substring, but NOT
# "vm-x86-64-wendyos". Without this append the kernel recipe is skipped and the
# build fails with no virtual/kernel provider.
#
# :append (not an override assignment) so it lands after the override is
# resolved. Same pattern meta-qemu-extensions uses for qemuarm64-wendyos.
COMPATIBLE_MACHINE:append = "|vm-x86-64-wendyos"

