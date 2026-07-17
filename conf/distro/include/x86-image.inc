# Generic x86_64 PC image configuration.

# A/B rootfs sizing: image == slot == .wendy payload, pinned to one constant
# (WENDYOS_ROOTFS_SIZE_KB:x86-wendyos) via floor==ceiling, so an OTA image can
# never outgrow its fixed on-device slot. The matching --fixed-size rootfsA/
# rootfsB slots are in meta-x86-extensions/files/wic/genericx86-ab.wks. On the
# OTA path (Phase 2) wendyos-update.inc requires this same file, so requiring it
# here too is idempotent (the only overlap, a WICVARS list entry, dedups harmlessly).
require conf/distro/include/wendyos-rootfs-size.inc

# No runtime package management (dnf), matching the rest of the fleet (the distro
# default is off; x86 used to be the only board turning it on). Two reasons:
#   - Immutable A/B: the rootfs slot is raw-overwritten by every OTA, so anything
#     dnf-installed into it is wiped on the next update — dnf-in-image buys nothing
#     on an A/B rootfs. The GPU userspace feed (Phase B) must use a non-dnf path
#     (baked / /data / container) regardless.
#   - Fixed-size pin: shipping dnf makes oe-core's rootfs_rpm add 100 MiB to
#     IMAGE_ROOTFS_EXTRA_SPACE, which breaks the floor==ceiling A/B slot sizing
#     (the ext4 must equal the fixed slot exactly). Off => EXTRA_SPACE = 0.
# sshd stays on — x86 is a dev/PC-class target and ssh is useful for bring-up.
WENDYOS_ENABLE_PACKAGE_MANAGEMENT:x86-wendyos ?= "0"
WENDYOS_SSHD:x86-wendyos ?= "1"

# Useful on commodity PCs and harmless on machines without a given bus/device.
# packagegroup-wendyos-x86 (meta-x86-extensions) carries the NUC network/BT/GPU
# kernel-module coverage as RRECOMMENDS.
#
# kernel-image puts /boot/${KERNEL_IMAGETYPE} (bzImage) INSIDE the rootfs so GRUB
# can load the kernel from the selected A/B slot's own /boot (grubAB.cfg), keeping
# each slot self-contained. The ESP carries only GRUB + grubenv
# (install-kernel-into-boot-dir=false in the wks), never the kernel.
# grub-editenv edits the A/B grubenv (EFI/BOOT/grubenv) from Linux — the analog of
# fw_setenv on RPi. Needed to flip the slot manually in Phase 1, and by the
# wendyos-update grubenv connector in Phase 2.
IMAGE_INSTALL:append = " \
    pciutils \
    linux-firmware \
    ca-certificates \
    packagegroup-wendyos-x86 \
    kernel-image \
    grub-editenv \
    "

# A/B wic build: GPT + ext4 label tooling, and DO NOT let wic write an fstab. The
# stock wic fstab update would bake a single "/" entry, wrong on the other slot;
# the A/B fstab (x86-wendy-fstab, no "/" entry, LABEL mounts) is installed by
# base-files instead. Mirrors rpi-image.inc.
WIC_CREATE_EXTRA_ARGS ?= "--no-fstab-update"
do_image_wic[depends] += " \
    wic-tools:do_populate_sysroot \
    e2fsprogs-native:do_populate_sysroot \
    gptfdisk-native:do_populate_sysroot \
    "

# --- wendyos-update (wendy OTA) image deltas for x86 -----------------------
# All gated on WENDYOS_OTA == "wendy". When set, wendyos.conf auto-requires
# wendyos-update.inc (installs the wendyos-update agent + wendyos-data-setup, and
# builds the .wendy payload) and packagegroup-wendyos-base pulls in
# wendyos-etc-binds (identity persists on /data across A/B slots).
#
# 1) Extra packages for the wendy A/B OTA image, added only when WENDYOS_OTA=="wendy":
#    - wendyos-update-config: pins the OTA connector to grubenv (meta-x86-extensions).
#    - grow-data-part: grows /data to fill the disk on first boot (shared,
#      board-agnostic; the wks makes /data the last partition so it can grow).
WENDYOS_X86_OTA_INSTALL = " \
    wendyos-update-config \
    grow-data-part \
    "
IMAGE_INSTALL:append = "${@' ' + d.getVar('WENDYOS_X86_OTA_INSTALL') if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"

# 2) Drop wendyos-data-setup (pulled by wendyos-update.inc). Its explicit
#    data.mount uses /dev/disk/by-partlabel/data and its data-init would not grow
#    our wic-preformatted ext4 /data anyway. x86 instead relies on the
#    fstab-generated data.mount (LABEL=data, x86-wendy-fstab) — proven mounting in
#    Phase 1 — which also satisfies wendyos-etc-binds' Requires=data.mount, plus
#    grow-data-part above for the first-boot grow. Mirrors rpi-image.inc.
IMAGE_INSTALL:remove = "${@'wendyos-data-setup' if d.getVar('WENDYOS_OTA') == 'wendy' else ''}"

# NVIDIA dGPU compute stack. When WENDYOS_NVIDIA_DGPU=1 this bakes the full
# driver stack into the image: the open kernel modules, the matching proprietary
# userspace, the container toolkit and the wendyos-gpu-cdi detect/CDI helper.
# Baking the proprietary userspace into a shipped image is a licensing question,
# so this is the current path (Phase A). The shipping path (Phase B) keeps the
# kernel modules baked and moves the userspace to a feed installed at first boot
# by the detect service. See docs/plans/x86-support-plan.md.
IMAGE_INSTALL:append = " \
    ${@oe.utils.ifelse(d.getVar('WENDYOS_NVIDIA_DGPU') == '1', 'packagegroup-wendyos-nvidia-graphics', '')} \
    "

# /config and /data mount points. With the A/B layout they are now real
# partitions (FAT config + ext4 data in genericx86-ab.wks) mounted by LABEL from
# the A/B fstab (x86-wendy-fstab), so the rootfs must carry empty mount-point
# directories for the mounts to land on. install -d is idempotent.
create_wendyos_dirs() {
    install -d -m 0755 ${IMAGE_ROOTFS}/config
    install -d -m 0755 ${IMAGE_ROOTFS}/data
}

ROOTFS_POSTPROCESS_COMMAND:append:x86-wendyos = " create_wendyos_dirs;"

# NVIDIA's prebuilt userspace binaries (nvidia-smi, nvidia-modprobe) use the
# x86-64 ABI loader path /lib64/ld-linux-x86-64.so.2, but OE only provides /lib.
# Add a /lib64 -> lib compat symlink so they execute. Gated on the NVIDIA stack
# so non-NVIDIA x86 images are untouched.
create_lib64_compat() {
    [ -e ${IMAGE_ROOTFS}/lib64 ] || ln -sf lib ${IMAGE_ROOTFS}/lib64
}

ROOTFS_POSTPROCESS_COMMAND:append:x86-wendyos = " ${@oe.utils.ifelse(d.getVar('WENDYOS_NVIDIA_DGPU') == '1', 'create_lib64_compat;', '')}"
