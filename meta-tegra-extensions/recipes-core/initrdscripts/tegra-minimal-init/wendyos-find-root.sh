#!/bin/sh
# Usage: wendyos-find-root <slot-suffix> <build-time-bootdrive|""> <none|undecided|bootdrive|any|late>
# Prints "root <dev> <bootcurrent|bootdrive|single-disk>" or "wait <reason>", and exits 0.

efivars=/sys/firmware/efi/efivars
sysblock=/sys/block
devdir=/dev

slot=$1
bootdrive=$2
fallbacks=$3
guid=8be4df61-93ca-11d2-aa0d-00e098032b8c

found() {
    echo "root $devdir/$1 $2"
    exit 0
}

# Whole disks only: not nvme0c0n1 (a multipath path), mmcblk0boot0 or partitions.
# A multipath head sits under nvme-subsystem, not the controller, so it never matches.
is_disk() {
    case "$1" in
        nvme*n*) num=${1#nvme}; ns=${num#*n}; num=${num%%n*} ;;
        mmcblk*) num=${1#mmcblk}; ns=0 ;;
        *) return 1 ;;
    esac
    case "$num:$ns" in
        *[!0-9:]* | :* | *:) return 1 ;;
    esac
}

# Prints "<nvme|mmc|sd> <controller-address> [<nsid> <eui>]" for the disk BootCurrent
# names, else "none <reason>". The address is assembled as hex text: awk has no 64-bit ints.
bootdisk() {
    opt=$(hexdump -v -e '/1 "%u "' "$efivars/BootCurrent-$guid" 2>/dev/null |
        awk 'NF == 6 { printf "Boot%04X", $5 + 256 * $6 }')
    if [ -z "$opt" ]; then
        echo "none no BootCurrent"
        return
    fi
    if [ ! -r "$efivars/$opt-$guid" ]; then
        echo "none no $opt"
        return
    fi
    hexdump -v -e '/1 "%u "' "$efivars/$opt-$guid" 2>/dev/null | awk -v opt="$opt" '
        function bad(why) { print "none " opt " " why; exit }
        function u16(i) { return b[i] + 256 * b[i + 1] }
        function hex(at, cnt, step,   s) {
            for (s = ""; cnt > 0; cnt--) { s = s sprintf("%02x", b[at]); at += step }
            return s
        }
        { for (k = 1; k <= NF; k++) b[n++] = $k + 0 }
        END {
            # 4 variable attribute bytes, then UINT32 Attributes, UINT16 FilePathListLength,
            # a NUL-terminated CHAR16 Description and the device path.
            i = 10
            while (i + 1 < n && (b[i] || b[i + 1])) i += 2
            end = i + 2 + u16(8)
            if (i + 1 >= n || end > n) bad("is malformed")
            for (i += 2; ; i += len) {
                if (i + 4 > end) bad("is malformed")
                len = u16(i + 2)
                if (len < 4 || i + len > end) bad("is malformed")
                t = sprintf("%02x%02x", b[i], b[i + 1])
                if (t ~ /^7f/) break
                if (media != "") continue
                if (t == "0103" && len == 24 && ctrl == "") ctrl = hex(i + 15, 8, -1)
                else if (t == "0317" && len == 16)
                    media = sprintf("nvme %.0f %s", u16(i + 4) + 65536 * u16(i + 6),
                        hex(i + 8, 8, 1))
                else if (t == "031d") media = "mmc"
                else if (t == "031a") media = "sd"
            }
            if (media == "") bad("is not an NVMe, eMMC or SD disk")
            sub(/^0+/, "", ctrl)
            if (ctrl == "") bad("names no controller")
            split(media, m, " ")
            print m[1], ctrl, m[2], m[3]
        }'
}

nvme_matches() {
    [ "$(cat "$sysblock/$1/nsid" 2>/dev/null)" = "$2" ] || return 1
    if [ "$3" = 0000000000000000 ] || [ ! -r "$sysblock/$1/eui" ]; then
        return 0
    fi
    [ "$(tr -d ' :' <"$sysblock/$1/eui" | tr A-F a-f)" = "$3" ]
}

# True when whole disk $2 is media $1; only device/type tells an SD card from eMMC.
is_media() {
    case "$1:$2" in
        nvme:nvme*) ;;
        mmc:mmcblk*) [ "$(cat "$sysblock/$2/device/type" 2>/dev/null)" = MMC ] ;;
        sd:mmcblk*) [ "$(cat "$sysblock/$2/device/type" 2>/dev/null)" = SD ] ;;
        *) return 1 ;;
    esac
}

# True when disk $1 sits behind controller $2: Linux names a platform device
# "<address>.<node>", e.g. 14160000.pcie.
behind() {
    case "$(readlink -f "$sysblock/$1")/" in
        */"$2".*) ;;
        *) return 1 ;;
    esac
}

# Sets ncand and cand from the whole disks behind controller $2 that match media $1.
candidates() {
    ncand=0
    cand=""
    for p in "$sysblock"/*; do
        d=${p##*/}
        is_disk "$d" || continue
        behind "$d" "$2" || continue
        is_media "$1" "$d" || continue
        [ "$1" != nvme ] || nvme_matches "$d" "$3" "$4" || continue
        ncand=$((ncand + 1))
        cand=$d
    done
}

# Reads disk $1's partition names from sysfs, so no device is opened before it settles.
scan() {
    nparts=0 nwant=0 want="" napp=0 app="" cfg=0 dat=0 esp=0
    for p in "$sysblock/$1/$1"*; do
        if [ ! -f "$p/partition" ] || [ ! -r "$p/uevent" ]; then
            continue
        fi
        nparts=$((nparts + 1))
        name=""
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in PARTNAME=*) name=${line#PARTNAME=} ;; esac
        done <"$p/uevent"
        if [ "$name" = "APP$slot" ]; then
            nwant=$((nwant + 1))
            want=${p##*/}
        fi
        case "$name" in
            APP) napp=$((napp + 1)); app=${p##*/} ;;
            config) cfg=1 ;;
            data) dat=1 ;;
            esp) esp=1 ;;
        esac
    done
}

# Sets part to disk $1's only APP$slot partition that has a device node.
# A disk without APP_b is not A/B, and slot B then runs from its APP.
usable() {
    scan "$1"
    if [ "$nwant" -eq 0 ] && [ "$slot" = _b ] && [ "$napp" -gt 0 ]; then
        # The kernel adds partitions one at a time, so APP_b may just not be there yet.
        seen=$nparts
        sleep 0.5
        scan "$1"
        if [ "$nwant" -eq 0 ] && [ "$nparts" -eq "$seen" ]; then
            nwant=$napp
            want=$app
        fi
    fi
    part=""
    if [ "$nwant" -eq 1 ] && [ -b "$devdir/$want" ]; then
        part=$want
    fi
    [ -n "$part" ]
}

e1=undecided
near=no
info=$(bootdisk)
read -r kind ctrl nsid eui <<EOF
$info
EOF
case "$kind" in
    nvme | mmc | sd)
        candidates "$kind" "$ctrl" "$nsid" "$eui"
        if [ "$ncand" -eq 1 ]; then
            e1=$cand
            usable "$cand" && found "$part" bootcurrent
            why="no usable APP$slot on $cand"
        elif [ "$ncand" -eq 0 ]; then
            e1=absent
            near=yes
            why="boot disk not found"
        else
            near=yes
            why="$ncand disks match the boot option"
        fi
        ;;
    *) why=${info#none } ;;
esac

# "undecided" keeps the build-time disk from beating a boot disk that is still enumerating.
if [ "$fallbacks" = bootdrive ] || [ "$fallbacks" = any ] || [ "$fallbacks" = late ] ||
    { [ "$fallbacks" = undecided ] && [ "$e1" = undecided ]; }; then
    case "$bootdrive" in
        /dev/*/* | /dev/) ;;
        /dev/*)
            usable "${bootdrive#/dev/}" && found "$part" bootdrive
            why="$why; no usable APP$slot on ${bootdrive#/dev/}"
            ;;
    esac
fi

# An undecided option, or late a boot disk never found, uses the one WendyOS disk (not JetPack).
# A lost or ambiguous boot disk takes only its media (NVMe: its controller); a stale install would confirm the trial slot.
single=no
case "$fallbacks:$e1" in
    any:undecided | late:undecided | late:absent) single=yes ;;
esac
if [ "$single" = yes ] && [ -z "$bootdrive" ]; then
    nwos=0
    for p in "$sysblock"/*; do
        d=${p##*/}
        is_disk "$d" || continue
        if [ "$near" = yes ]; then
            is_media "$kind" "$d" || continue
            [ "$kind" != nvme ] || behind "$d" "$ctrl" || continue
        fi
        scan "$d"
        if [ "$napp" -gt 0 ] && [ "$cfg$dat$esp" = 111 ]; then
            nwos=$((nwos + 1))
            wos=$d
        fi
    done
    if [ "$nwos" -eq 1 ]; then
        usable "$wos" && found "$part" single-disk
        why="$why; no usable APP$slot on $wos"
    elif [ "$nwos" -gt 1 ]; then
        why="$why; $nwos WendyOS disks"
    fi
fi

echo "wait $why"
