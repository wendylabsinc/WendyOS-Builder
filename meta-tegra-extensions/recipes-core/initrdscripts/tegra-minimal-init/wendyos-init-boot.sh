#!/bin/sh
# shellcheck disable=SC1091,SC2003,SC2006,SC2013,SC2086,SC2162,SC2166 # upstream's lines kept verbatim for re-merging
PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc -o nosuid,nodev,noexec /proc
mount -t devtmpfs none -o nosuid /dev
mount -t sysfs sysfs -o nosuid,nodev,noexec /sys
mount -t efivarfs efivarfs -o nosuid,nodev,noexec /sys/firmware/efi/efivars

find /sys -name modalias | while read m; do
    modalias=$(cat "$m")
    modprobe -v "$modalias" 2> /dev/null
done

modprobe -v nvme

rootdev=""
opt="rw"
wait=""
fstype="auto"

[ ! -f /etc/platform-preboot ] || . /etc/platform-preboot

if [ -z "$rootdev" ]; then
    for bootarg in `cat /proc/cmdline`; do
        case "$bootarg" in
            root=*) rootdev="${bootarg##root=}" ;;
            ro) opt="ro" ;;
            rootwait) wait="yes" ;;
            rootfstype=*) fstype="${bootarg##rootfstype=}" ;;
        esac
    done
fi

# Only a device path can still appear: an empty root or a root=LABEL= token would wait forever
# and skip the failure handling below.
if [ -n "$wait" -a "${rootdev#/}" != "${rootdev}" -a ! -b "${rootdev}" ]; then
    echo "Waiting for ${rootdev}..."
    while true; do
        test -b "${rootdev}" && break
        sleep 0.1
    done
fi

echo "Mounting ${rootdev}..."
[ -d /mnt ] || mkdir -p /mnt
count=0
while [ $count -lt 5 ]; do
    if mount -t "${fstype}" -o "${opt}" "${rootdev}" /mnt; then
        # -L too: an absolute /sbin/init symlink only resolves after switch_root.
        if [ -e /mnt/sbin/init ] || [ -L /mnt/sbin/init ]; then
            break
        fi
        echo "No /sbin/init on ${rootdev}"
        umount /mnt
    fi
    sleep 1.0
    count=`expr $count + 1`
done
if [ $count -ge 5 ]; then
    # With A/B, an unconfirmed reboot counts against this slot until the firmware switches slots.
    rlevel=$(hexdump -n 8 -e '2/4 " %u"' /sys/firmware/efi/efivars/RootfsRedundancyLevel-781e084c-a330-417c-b678-38e696380cb9 2>/dev/null)
    case "$rlevel" in
        " "*" 1")
            echo "Cannot mount the root filesystem; rebooting so the firmware retries or switches slots"
            sleep 5
            reboot -f
            ;;
    esac
    exec sh
fi

[ ! -f /etc/platform-pre-switchroot ] || . /etc/platform-pre-switchroot

echo "Switching to rootfs on ${rootdev}..."
mount --move /sys  /mnt/sys
mount --move /proc /mnt/proc
mount --move /dev  /mnt/dev
exec switch_root /mnt /sbin/init
