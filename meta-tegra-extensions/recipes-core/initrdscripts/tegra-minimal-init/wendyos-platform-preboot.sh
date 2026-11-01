# shellcheck disable=SC2005,SC2006,SC2013,SC2034,SC2046 # upstream's lines kept verbatim for re-merging
# Sourced by /init, which is PID 1: an exit or a failed expansion here panics the kernel.
# The root comes from the disk UEFI booted, so firmware on slot B never gets slot A's APP.
findroot=@@FINDROOT@@
devdir=/dev
slotsfx=""
mayberoot=""
foundslotsfx="no"
bootdrive=@@BOOTDRIVE@@
for bootarg in `cat /proc/cmdline`; do
    case "$bootarg" in
        boot.slot_suffix=*) slotsfx="${bootarg##boot.slot_suffix=}"; foundslotsfx="yes" ;;
        root=*) mayberoot="${bootarg##root=}" ;;
        ro) opt="ro" ;;
        rootwait) wait="yes" ;;
        rootfstype=*) fstype="${bootarg##rootfstype=}" ;;
    esac
done

if [ "$foundslotsfx" != "yes" ]; then
    # This variable file contains a type (should be 6) followed by the value (should be 0 or 1)
    bcdata=$(echo $(hexdump -n 8 -e '2/4 " %u"' /sys/firmware/efi/efivars/BootChainOsCurrent-781e084c-a330-417c-b678-38e696380cb9 2>/dev/null))
    if [ "$(echo "$bcdata" | cut -d' ' -f1)" = "6" ]; then
        slotnum=$(echo "$bcdata" | cut -d' ' -f2)
        [ "$slotnum" != "1" ] || slotsfx="_b"
    fi
fi
# L4T names slot A's partition plain APP.
[ "$slotsfx" != "_a" ] || slotsfx=""

# Give up after two minutes: /init then reboots an A/B unit or opens a rescue shell,
# unless root= with rootwait names a device for it to wait for.
pass=0
while [ "$pass" -lt 240 ]; do
    fallbacks=none
    if [ -n "$bootdrive" ]; then
        # A disk BootCurrent names gets 5 s to appear before the build-time disk is trusted.
        fallbacks=undecided
        [ "$pass" -lt 10 ] || fallbacks=bootdrive
    elif [ "$pass" -ge 120 ]; then
        # A boot disk unseen after a minute gives way to the one WendyOS disk of its media; for an
        # NVMe only one behind the same controller, so a wrongly decoded controller waits.
        fallbacks=late
    elif [ "$pass" -ge 30 ]; then
        # Let a second disk enumerate before trusting the only WendyOS disk seen.
        fallbacks=any
    fi
    answer=$("$findroot" "$slotsfx" "$bootdrive" "$fallbacks" 2>/dev/null)
    src=${answer##* }
    name=${answer#"root $devdir/"}
    name=${name%" $src"}
    case "$src" in bootcurrent | bootdrive | single-disk) ;; *) name="" ;; esac
    case "$name" in */* | *" "*) name="" ;; esac
    if [ -n "$name" ] && [ "$answer" = "root $devdir/$name $src" ] && [ -b "$devdir/$name" ]; then
        rootdev="$devdir/$name"
        echo "[OK: $rootdev ($src)]"
        break
    fi
    case "$answer" in
        "wait "*) why=${answer#wait } ;;
        *) why="no answer from $findroot" ;;
    esac

    if [ "$pass" -ge 10 ] && [ -n "$mayberoot" ]; then
        case "$mayberoot" in
            UUID=* | PARTUUID=* | PARTLABEL=* | LABEL=*)
                rootarg=$(blkid -t "$mayberoot" -l 2>/dev/null | awk -F: '{ print $1 }') ;;
            *) rootarg="$mayberoot" ;;
        esac
        if [ -b "$rootarg" ]; then
            rootdev="$rootarg"
            echo "[OK: $rootdev (root=)]"
            break
        fi
    fi

    if [ $((pass % 10)) -eq 0 ]; then
        echo "Waiting for APP$slotsfx: $why"
    fi
    sleep 0.5
    pass=$((pass + 1))
done
[ -n "$rootdev" ] || echo "[FAIL: no APP$slotsfx: $why]"
