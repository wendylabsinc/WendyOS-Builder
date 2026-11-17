# Enable the GlobalPlatform PKCS#11 Trusted Application in the OP-TEE build.
#
# CFG_PKCS11_TA=y compiles the Cryptoki token TA (ta/pkcs11/*.ta) so the
# device can store keys (device-tls, UEFI PK/KEK) in OP-TEE secure storage
# instead of in cleartext on the rootfs.
#
# The base recipe's do_install harvests every built *.ta from ${B}/ta into
# /lib/optee_armtz (FILES:${PN}), so enabling this config is enough — no extra
# install rule is needed here. Delivery to the device happens via the optee-os
# runtime package (see recipes-core/packagegroups/tegra-packagegroup-base.inc);
# tee-supplicant loads the TA from REE-FS on demand at runtime.
#
# Version-agnostic _%.bbappend so it survives meta-tegra version bumps
# (optee-os recipe version changes).
EXTRA_OEMAKE += "CFG_PKCS11_TA=y"

# Make OP-TEE check the single-instance TA lock again at a fixed interval
# while it waits for it.
#
# Only one single-instance TA can run at a time. The fTPM and StMM (which
# serves UEFI variables) are both single-instance. A thread waiting for that
# lock sleeps until the thread that drops it sends a wake-up through Linux.
# On t234, StMM calls come from UEFI runtime services, and from there OP-TEE
# cannot reach Linux. So when StMM drops the lock, the wake-up is lost, and
# the waiter (for example the fTPM driver load) hangs for good. The patch
# makes the wait wake up every CFG_MUTEX_POLL_INTERVAL and check the lock
# again. That is the interval NVIDIA already uses on t234 to poll mutexes
# for StMM. Where the interval is 0 (t264, Thor), the patched code is the
# same as the stock code.
#
# The patch also prints "Wake-up for thread N could not be sent" on the
# OP-TEE console each time a wake-up is lost this way. Stock OP-TEE logs it
# only at debug level, so the line is the evidence that polling was needed.
#
# "1" applies the patch. "0" builds the stock OP-TEE. Set it in local.conf.
# OP-TEE is part of the bootloader, so changing this value changes the
# bootloader capsule too.
WENDYOS_OPTEE_SI_POLL ?= "1"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = "${@' file://0001-core-poll-single-instance-lock-wait.patch;striplevel=2' if d.getVar('WENDYOS_OPTEE_SI_POLL') == '1' else ''}"
