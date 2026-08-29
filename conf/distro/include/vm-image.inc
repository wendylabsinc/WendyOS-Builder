# WendyOS VM image configuration.
# Required from wendyos-image.bb when MACHINEOVERRIDES contains "vm-wendyos".
#
# Origin: conf/distro/include/x86-image.inc, trimmed to what a VM needs. What was
# deliberately dropped, and why:
#   - packagegroup-wendyos-x86  lives in meta-x86-extensions, which the VM boards
#                               do not layer. It is NUC network/BT/GPU modules.
#   - linux-firmware            device firmware for physical cards, radios and GPUs;
#                               a guest has none. NOTE: dropping it from
#                               IMAGE_INSTALL here is NOT what removes it -- the BSP
#                               re-adds it through MACHINE_EXTRA_RRECOMMENDS, so the
#                               cut that actually works is the :remove in
#                               conf/machine/vm-x86-64-wendyos.conf. That one is
#                               worth 1.8 GiB; this line alone was worth nothing.
#   - the NVIDIA dGPU block     out of scope (no GPU passthrough).
#   - the TPM/LUKS block        WENDYOS_DATA_ENCRYPTED defaults off for a VM and
#                               meta-tpm is not layered. See vm-distro.inc.
# create_lib64_compat is KEPT (below) — it is not NVIDIA-only in effect.

# A/B rootfs sizing: image == slot == .wendy payload, pinned to one constant via
# floor==ceiling, so an OTA image can never outgrow its fixed on-device slot. The
# VM machine overrides WENDYOS_ROOTFS_SIZE_KB:vm-wendyos from its own
# WENDYOS_VM_ROOTFS_SIZE_KB knob. The matching --fixed-size rootfsA/rootfsB slots
# are in meta-vm-extensions/files/wic/vm-ab.wks, which reads the same variable
# (exported to wic via WICVARS in this include). On the OTA path wendyos-update.inc
# requires this same file, so requiring it here too is idempotent.
require conf/distro/include/wendyos-rootfs-size.inc

# sshd on: a VM is a developer target and there is no serial cable to fall back on.
WENDYOS_SSHD:vm-wendyos ?= "1"

# kernel-image puts /boot/${KERNEL_IMAGETYPE} (bzImage) INSIDE the rootfs so GRUB
# can load the kernel from the selected A/B slot's own /boot (vm-grubAB-x64.cfg),
# keeping each slot self-contained. The ESP carries only GRUB + grubenv
# (install-kernel-into-boot-dir=false in the wks), never the kernel.
# grub-editenv edits the A/B grubenv (EFI/BOOT/grubenv) from Linux — needed by the
# wendyos-update grubenv connector, and to flip the slot by hand when debugging.
IMAGE_INSTALL:append = " \
    pciutils \
    ca-certificates \
    kernel-image \
    grub-editenv \
    "

# A/B wic build: GPT + ext4 label tooling, and DO NOT let wic write an fstab. The
# stock wic fstab update would bake a single "/" entry, wrong on the other slot;
# the A/B fstab (vm-wendy-fstab, no "/" entry, LABEL mounts) is installed by
# base-files instead. Mirrors x86-image.inc / rpi-image.inc.
WIC_CREATE_EXTRA_ARGS ?= "--no-fstab-update"
do_image_wic[depends] += " \
    wic-tools:do_populate_sysroot \
    e2fsprogs-native:do_populate_sysroot \
    gptfdisk-native:do_populate_sysroot \
    "

# --- wendyos-update (wendy OTA) image deltas ------------------------------
# Gated on WENDYOS_OTA == "wendy". When set, wendyos.conf auto-requires
# wendyos-update.inc (the client + wendyos-data-setup + the .wendy payload) and
# packagegroup-wendyos-base pulls in wendyos-etc-binds.
#
# 1) wendyos-update-config pins the OTA connector to grubenv (meta-vm-extensions).
#    grow-data-part grows /data to fill the disk on first boot (board-agnostic;
#    the wks makes /data the last partition so it can grow).
WENDYOS_VM_OTA_INSTALL = " \
    wendyos-update-config \
    grow-data-part \
    "
IMAGE_INSTALL:append = "${@' ' + d.getVar('WENDYOS_VM_OTA_INSTALL') if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"

# 2) Drop wendyos-data-setup (pulled by wendyos-update.inc). Its explicit
#    data.mount uses /dev/disk/by-partlabel/data and its data-init would not grow
#    our wic-preformatted ext4 /data anyway. The VM instead relies on the
#    fstab-generated data.mount (LABEL=data, vm-wendy-fstab), which also satisfies
#    wendyos-etc-binds' Requires=data.mount, plus grow-data-part above for the
#    first-boot grow. Mirrors x86-image.inc / rpi-image.inc.
IMAGE_INSTALL:remove = "${@'wendyos-data-setup' if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"

# /config and /data mount points. Both are real partitions in vm-ab.wks mounted by
# LABEL from vm-wendy-fstab, so the rootfs must carry empty mount-point
# directories for the mounts to land on. install -d is idempotent.
create_wendyos_vm_dirs() {
    install -d -m 0755 ${IMAGE_ROOTFS}/config
    install -d -m 0755 ${IMAGE_ROOTFS}/data
}

ROOTFS_POSTPROCESS_COMMAND:append:vm-wendyos = " create_wendyos_vm_dirs;"

# /lib64 -> lib compatibility symlink. x86-image.inc has the same helper but gates
# it on the NVIDIA stack, describing it as a fix for NVIDIA's prebuilt binaries.
# That undersells it: the wendy AGENT needs it too, so this copy is ungated.
#
# The agent baked into the image is statically linked and runs fine. But
# wendyos-agent-updater.timer fires a few minutes after boot and replaces
# /opt/wendyos/bin/wendy-agent with the upstream release tarball's build, which is
# DYNAMICALLY linked against the x86-64 ABI loader path /lib64/ld-linux-x86-64.so.2.
# OE is usrmerge: /lib is a symlink to usr/lib, the loader is at
# /usr/lib/ld-linux-x86-64.so.2, and /lib64 does not exist. So the updated agent
# dies with "cannot execute: required file not found" (systemd 203/EXEC) on a
# restart loop, a few minutes into every boot. Verified on the first VM boot.
#
# The generic-x86-64 board never sees this because WENDYOS_NVIDIA_DGPU defaults to
# "1" there, so its gated symlink is always created. Setting that knob to "0" on
# that board would break the agent the same way.
create_lib64_compat() {
    [ -e ${IMAGE_ROOTFS}/lib64 ] || ln -sf lib ${IMAGE_ROOTFS}/lib64
}

ROOTFS_POSTPROCESS_COMMAND:append:vm-wendyos = " create_lib64_compat;"

