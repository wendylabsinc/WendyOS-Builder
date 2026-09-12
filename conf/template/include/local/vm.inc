# WendyOS VM defaults.
#
# Target: a developer's machine running QEMU/KVM (or any plain UEFI hypervisor).
# The image is a full WendyOS device minus peripherals and GPU.

# No USB peripheral controller in a VM; discovery happens on the host network.
WENDYOS_USB_GADGET = "0"
WENDYOS_MDNS_INTERFACES = ""

# Console login on the serial port. The VM is normally run headless
# (qemu -nographic), so the serial console is the only way in before sshd is up,
# and there is no physical console to protect. Root stays locked either way — log
# in as the wendy user (passwordless sudo). Set to "0" to match the hardware
# fleet's default of no interactive login at all.
WENDYOS_ENABLE_UART_LOGIN ?= "1"

# Two knobs worth knowing about are deliberately NOT defaulted here — the machine
# conf owns them, so there is one value to change rather than two that can drift.
# Override either in this file with a hard "=" (local.conf is parsed before machine
# confs, so a "=" here wins over the machine's "?="):
#
#   WENDYOS_VM_ROOTFS_SIZE_KB   A/B slot size, and so the total disk image size:
#                               ESP 128M + config 256M + 2 x slot + data 512M.
#                               Default 3 GiB/slot => a ~6.9 GiB sparse .wic. The
#                               pin is floor==ceiling, so too small fails the build
#                               loudly. Keep a multiple of 128 MiB.
#   WENDYOS_OTA                 "wendy" (default) gives the full A/B OTA stack,
#                               persistent /data and identity that survives a slot
#                               switch — the point of a simulated device. "none"
#                               gives a lightweight single-slot image, no updates.

