#!/usr/bin/env bash
# Tests for wendyos-data.sh — plain bash, no framework, same shape as
# wendyos-agent-updater.test.sh.
#
# What differs is where it runs. The program under test grows a partition and
# then keeps or makes the filesystem on it, so it needs root and a real
# partition table on a real block device. On any machine with Docker:
#
#     bash recipes-support/data-device/files/wendyos-data.test.sh
#
# starts a throwaway privileged alpine container and runs this file again
# inside it, against loop devices backed by files in that container. No disk of
# the machine it runs on is touched. Set WENDYOS_DATA_SH to run the same cases
# against another copy of the program.
#
# The program runs whole and unmodified, the way wendyos-data.service starts it:
# `sh wendyos-data.sh`, with /config not mounted, so the encryption flag reads
# as unset and the run takes the plain path. Only the conversion cases at the
# end mount an ext4 /config armed for encryption. Each "boot" below is one run.
# Only root-disk-part is replaced, because it names the /data partition on the
# disk / is mounted from and a container's / is not on a disk.
#
# A "flash" writes an image smaller than the disk the way the flash tools do:
# everything in front of the /data partition, and the backup GPT behind it.
# Inside the partition it writes only what the image carries there, which is
# nothing on the boards whose layout carves /data empty (Jetson) and a small
# ext4 on the boards whose image ships one (Pi, x86, VM).
#
# Covers WDY-4295, "first boot reuses the old /data after a reflash":
#   (a) a reflash over a used disk: the previous installation's filesystem is
#       larger than the partition as flashed, so it is erased BEFORE the grow
#       and a new one is made over the whole grown partition. Before the fix
#       the partition was grown first, the old filesystem fitted it again and
#       the board came back with its old identity.
#   (b) the same, with the first boot cut short between the grow and the mkfs:
#       the next boot must not find the old filesystem either.
#   (c) the same on a board whose /data cannot grow: remade at the flashed size.
#   (d) a healthy /data is kept: a later boot, a boot after the other root slot
#       was rewritten, a first boot of an image that ships its own filesystem on
#       a larger disk, a first boot cut short after the partition grew or part
#       way through the filesystem resize, and a board with no room to grow.
#   (e) the board that finds /data by its filesystem label (MBR) is never
#       erased ahead of the grow, because the label is the only name it has.
#   (f) a reflash with encryption requested: the conversion erases the old
#       filesystem too, so there is nothing to carry and the partition grows.
#   (g) encryption requested on a used disk that was not reflashed: nothing is
#       erased before the identity carry, and the identity reaches /config.
#   (h) the conversion's erase ends the boot while an earlier attempt's marker
#       is still there: the marker must not survive, or /data never mounts.
#
# Not covered: the LUKS container and everything after it (it needs a TPM; the
# conversion cases stop at luksFormat), the MBR extended container, and the
# online resize unit, whose result is stood in for by resize2fs.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "${1:-}" != "--inside" ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "SKIP - wendyos-data.test.sh requires docker: it needs root and loop devices, and gets both from a privileged container" >&2
        exit 99
    fi
    under_test=${WENDYOS_DATA_SH:-${SCRIPT_DIR}/wendyos-data.sh}
    if [ ! -f "${under_test}" ]; then
        echo "FAIL - no program to test at ${under_test}" >&2
        exit 1
    fi
    exec docker run --rm --privileged \
        -v "${SCRIPT_DIR}/wendyos-data.test.sh:/test/wendyos-data.test.sh:ro" \
        -v "${under_test}:/test/wendyos-data.sh:ro" \
        alpine:3 sh -c 'apk add -q bash coreutils e2fsprogs e2fsprogs-extra parted util-linux \
            && exec bash /test/wendyos-data.test.sh --inside'
fi

# --- inside the container ------------------------------------------------------
# Everything below rearranges /dev, so it must never run on a real machine.
if [ ! -f /.dockerenv ]; then
    echo "FAIL - --inside is for the container this test starts, not for a host" >&2
    exit 1
fi

SCRIPT=/test/wendyos-data.sh
STALE_LINE="does not fit the partition (a stale superblock from a prior, larger layout), so it is being remade"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

# A harness that cannot set its fixture up must not read as a pass.
die() {
    echo "FAIL - setup: $1" >&2
    exit 1
}

WORK=$(mktemp -d)
KDEV="${WORK}/kdev"
MNT="${WORK}/mnt"
STUBS="${WORK}/stubs"
NO_MKFS="${WORK}/no-mkfs"
NO_WIPEFS="${WORK}/no-wipefs"
mkdir -p "${KDEV}" "${MNT}" "${STUBS}" "${NO_MKFS}" "${NO_WIPEFS}"

LOOP=""
DATA=""
OUT=""
RC=0
FS_UUID=""

detach() {
    umount "${MNT}" 2>/dev/null
    umount /config 2>/dev/null
    if [ -n "${LOOP}" ]; then
        losetup -d "${LOOP}" 2>/dev/null
        rm -f "${LOOP}"p[0-9]
    fi
    LOOP=""
    DATA=""
}

cleanup() {
    detach
    rm -rf /dev/wendyos
    rm -f /dev/tpmrm0
    umount /dev/console /dev/ttyS0 2>/dev/null
    umount "${KDEV}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

# The container's /dev is a tmpfs Docker filled in when it started, so it never
# learns about a loop partition made later. devtmpfs is the kernel's own view,
# where a partition's node comes and goes with the partition. It is mounted
# beside /dev and linked into it, not over it: /dev stays the container's own,
# so nothing made there (/dev/wendyos/data) appears on the machine.
mount -t devtmpfs devtmpfs "${KDEV}" || die "cannot mount devtmpfs"

# The program repeats every line on /dev/console and /dev/ttyS0 when it can
# write to them. In a privileged container those are the machine's.
for con in /dev/console /dev/ttyS0; do
    if [ -e "${con}" ]; then
        mount --bind /dev/null "${con}" || die "cannot cover ${con}"
    fi
done

# root-disk-part NAME prints the partition called NAME on the root disk. Here
# it prints the partition the fixture names, and fails when it names none, which
# is what the real one does on an MBR table.
cat > "${STUBS}/root-disk-part" <<EOF
#!/bin/sh
if [ "\${1:-}" = data ] && [ -s "${WORK}/data-part" ]; then
    cat "${WORK}/data-part"
    exit 0
fi
echo "root-disk-part: no partition is named '\${1:-}' (test fixture)" >&2
exit 1
EOF
# A mkfs.ext4 that fails without writing anything: on the disk, a boot that
# reaches it and stops there is a boot that lost power just before it.
printf '#!/bin/sh\nexit 1\n' > "${NO_MKFS}/mkfs.ext4"
# A wipefs that fails: the erase of a stale filesystem then ends the program.
printf '#!/bin/sh\nexit 1\n' > "${NO_WIPEFS}/wipefs"
chmod +x "${STUBS}/root-disk-part" "${NO_MKFS}/mkfs.ext4" "${NO_WIPEFS}/wipefs"

# The crypt tools the conversion requires. luksFormat fails, which stops the
# conversion at a known step: after the identity carry, the grow and the wipe.
CRYPT="${WORK}/crypt"
mkdir -p "${CRYPT}"
cat > "${CRYPT}/cryptsetup" <<'EOF'
#!/bin/sh
[ "$1" = luksFormat ] && exit 1
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "${CRYPT}/systemd-cryptenroll"
printf '#!/bin/sh\nexit 0\n' > "${CRYPT}/systemd-cryptsetup"
chmod +x "${CRYPT}/cryptsetup" "${CRYPT}/systemd-cryptenroll" "${CRYPT}/systemd-cryptsetup"

# --- the fixture ---------------------------------------------------------------
# Sizes in MiB. The image is what gets flashed: config, then /data at its stock
# size as the last partition, then room for the backup GPT.
MIB=$((1024 * 1024))
DATA_START=16
DATA_SIZE=64
DATA_END=$((DATA_START + DATA_SIZE))
IMAGE_SIZE=$((DATA_END + 3))
BIG_DISK=320

# new_disk SIZE_MIB — an empty disk of that size, attached as ${LOOP}.
new_disk() {
    detach
    rm -f "${WORK}/disk.img"
    truncate -s "${1}M" "${WORK}/disk.img" || die "cannot create the disk file"
    # Twice: when every loop device is taken the kernel makes a new one on the
    # first try, and its node is only linked into /dev on the second.
    for _ in 1 2; do
        ln -sf "${KDEV}"/loop[0-9]* /dev/ 2>/dev/null
        LOOP=$(losetup -fP --show "${WORK}/disk.img" 2>/dev/null) && break
        LOOP=""
    done
    [ -n "${LOOP}" ] || die "no loop device"
    for n in 1 2 3; do
        ln -sf "${KDEV}/${LOOP##*/}p${n}" "${LOOP}p${n}"
    done
    DATA="${LOOP}p2"
    echo "${DATA}" > "${WORK}/data-part"
    rm -rf /dev/wendyos
}

# flash LAYOUT CONTENT
#   LAYOUT   gpt       config and data
#            gpt-tail  the same with a partition behind /data, so it cannot grow
#            dos       the same two partitions in an MBR table
#   CONTENT  empty     the image carries nothing in /data
#            fs        the image carries a small ext4 there
flash() {
    local layout="$1" content="$2" img="${WORK}/image.img" table
    rm -f "${img}"
    truncate -s "${IMAGE_SIZE}M" "${img}" || die "cannot create the image file"
    case "${layout}" in
        gpt|gpt-tail)
            table="label: gpt
start=$((MIB / 512)), size=$((8 * MIB / 512)), name=config
start=$((DATA_START * MIB / 512)), size=$((DATA_SIZE * MIB / 512)), name=data"
            if [ "${layout}" = gpt-tail ]; then
                table="${table}
start=$((DATA_END * MIB / 512)), size=$((MIB / 512)), name=tail"
            fi
            ;;
        dos)
            table="label: dos
start=$((MIB / 512)), size=$((8 * MIB / 512)), type=c
start=$((DATA_START * MIB / 512)), size=$((DATA_SIZE * MIB / 512)), type=83"
            ;;
        *)
            die "unknown layout ${layout}"
            ;;
    esac
    echo "${table}" | sfdisk -q "${img}" >/dev/null 2>&1 || die "sfdisk could not write the image's partition table"

    dd if="${img}" of="${LOOP}" bs=1M count="${DATA_START}" conv=notrunc status=none \
        || die "cannot write the head of the image"
    if [ "${content}" = fs ]; then
        mkfs.ext4 -q -F -L data -E "offset=$((DATA_START * MIB))" "${img}" "${DATA_SIZE}M" \
            || die "cannot make the image's /data filesystem"
        dd if="${img}" of="${LOOP}" bs=1M skip="${DATA_START}" seek="${DATA_START}" count="${DATA_SIZE}" \
            conv=notrunc status=none || die "cannot write the image's /data"
    fi
    dd if="${img}" of="${LOOP}" bs=1M skip="${DATA_END}" seek="${DATA_END}" conv=notrunc status=none \
        || die "cannot write the tail of the image"
    sync
    blockdev --rereadpt "${LOOP}" || die "the kernel did not re-read the partition table"
    [ -b "${DATA}" ] || die "no /data partition after the flash"
}

# One boot: the whole program. Sets OUT and RC. An argument is
# a directory put in front of PATH for this boot only.
boot() {
    OUT=$(PATH="${1:+$1:}${STUBS}:${PATH}" sh "${SCRIPT}" 2>&1)
    RC=$?
}

# What a board would lose first: its identity. seed writes it into /data and
# notes which filesystem it went into.
seed() {
    mount -t ext4 "${DATA}" "${MNT}" || die "cannot mount /data to write the device identity"
    mkdir -p "${MNT}/etc/wendyos"
    echo "0b9e8a52-old-installation" > "${MNT}/etc/wendyos/device-uuid"
    umount "${MNT}" || die "cannot unmount /data"
    FS_UUID=$(blkid -p -o value -s UUID "${DATA}")
}

# 0 the identity is there, 1 /data mounts and it is not, 2 /data does not mount.
identity() {
    mount -t ext4 -o ro "${DATA}" "${MNT}" 2>/dev/null || return 2
    local rc=1
    [ -f "${MNT}/etc/wendyos/device-uuid" ] && rc=0
    umount "${MNT}"
    return "${rc}"
}

part_bytes() { blockdev --getsize64 "${DATA}"; }

fs_bytes() {
    dumpe2fs -h "${DATA}" 2>/dev/null | awk -F: '
        /^Block count:/ { blocks = $2 }
        /^Block size:/  { size = $2 }
        END             { print blocks * size }'
}

# The predicate the program uses: the partition ends within 8192 sectors of
# the disk's end.
fills_disk() {
    local p="${DATA##*/}" d="${LOOP##*/}"
    [ $(($(cat "/sys/class/block/${p}/start") + $(cat "/sys/class/block/${p}/size"))) \
        -ge $(($(cat "/sys/class/block/${d}/size") - 8192)) ]
}

show_out() {
    printf '%s\n' "${OUT}" | sed 's/^/       | /'
}

# expect_kept LABEL [LINE] — the boot succeeded and left /data alone: same
# filesystem, identity still in it, nothing remade. LINE, when given, must be
# in the output.
expect_kept() {
    local why=""
    identity
    case $? in
        1) why="the device identity is gone" ;;
        2) why="/data does not mount" ;;
    esac
    [ "${RC}" -eq 0 ] || why="${why:+$why, }exit ${RC}"
    [ "$(blkid -p -o value -s UUID "${DATA}")" = "${FS_UUID}" ] || why="${why:+$why, }the filesystem was replaced"
    case "${OUT}" in
        *"is being remade"*|*"making the filesystem"*) why="${why:+$why, }the program said it made a filesystem" ;;
    esac
    if [ -n "${2:-}" ]; then
        case "${OUT}" in
            *"$2"*) ;;
            *) why="${why:+$why, }no '$2' line" ;;
        esac
    fi
    if [ -z "${why}" ]; then
        ok "$1"
    else
        bad "$1: ${why}"
        show_out
    fi
}

# expect_new LABEL grown|flashed [LINE] — the boot succeeded and /data is a new,
# empty filesystem that fills its partition. grown: the partition reaches the
# end of the disk. flashed: it is still the size it was flashed at.
expect_new() {
    local why="" part fs
    identity
    case $? in
        0) why="the previous installation's device identity is still there" ;;
        2) why="/data does not mount" ;;
    esac
    [ "${RC}" -eq 0 ] || why="${why:+$why, }exit ${RC}"
    [ "$(blkid -p -o value -s UUID "${DATA}")" != "${FS_UUID}" ] || why="${why:+$why, }the old filesystem is still there"
    part=$(part_bytes)
    fs=$(fs_bytes)
    if [ "${fs:-0}" -gt "${part}" ] || [ $((part - ${fs:-0})) -ge "${MIB}" ]; then
        why="${why:+$why, }the filesystem is ${fs:-0} bytes on a partition of ${part}"
    fi
    case "$2" in
        grown)   fills_disk || why="${why:+$why, }the partition did not grow" ;;
        flashed) [ "${part}" -eq $((DATA_SIZE * MIB)) ] || why="${why:+$why, }the partition is ${part} bytes" ;;
    esac
    if [ -n "${3:-}" ]; then
        case "${OUT}" in
            *"$3"*) ;;
            *) why="${why:+$why, }no '$3' line" ;;
        esac
    fi
    if [ -z "${why}" ]; then
        ok "$1"
    else
        bad "$1: ${why}"
        show_out
    fi
}

# A used board whose layout carves /data empty: flashed onto a blank disk,
# booted once, identity written.
used_board() {
    new_disk "${BIG_DISK}"
    flash gpt empty
    boot
    if [ "${RC}" -ne 0 ] || ! fills_disk; then
        die "the first boot of a blank disk did not leave a grown /data"
    fi
    seed
}

# An ext4 /config on the fixture's config partition, armed for encryption, and
# a TPM node for the program to find. detach unmounts it.
arm_encryption() {
    mkfs.ext4 -q -F -L config "${LOOP}p1" || die "cannot make the /config filesystem"
    mkdir -p /config
    mount -t ext4 "${LOOP}p1" /config || die "cannot mount /config"
    echo "data_encryption=1" > /config/data.conf
    [ -e /dev/tpmrm0 ] || mknod /dev/tpmrm0 c 1 3 || die "cannot make a TPM node"
}

# expect_converted — prints why the conversion did not run up to the failing
# luksFormat and leave no marker and a mountable /data without the identity.
# Prints nothing when it did.
expect_converted() {
    local why=""
    case "${OUT}" in
        *"luksFormat of ${DATA} failed"*) ;;
        *) why="the conversion did not reach luksFormat" ;;
    esac
    [ "${RC}" -eq 1 ] || why="${why:+$why, }exit ${RC}"
    grep -qx 'result=convert_failed' /config/data.status 2>/dev/null \
        || why="${why:+$why, }data.status does not say convert_failed"
    [ ! -e /config/data.enroll.pending ] || why="${why:+$why, }the conversion marker was left behind"
    identity
    case $? in
        0) why="${why:+$why, }the device identity is still on /data" ;;
        2) why="${why:+$why, }/data does not mount" ;;
    esac
    printf '%s\n' "${why}"
}

# --- (a) a reflash over a used disk ------------------------------------------
used_board
flash gpt empty
[ "$(part_bytes)" -eq $((DATA_SIZE * MIB)) ] || die "the reflash did not put /data back at its flashed size"
[ "$(blkid -p -o value -s TYPE "${DATA}")" = ext4 ] || die "the reflash did not leave the old filesystem behind"
boot
expect_new "reflash: the previous installation's filesystem is remade, over the whole disk" grown "${STALE_LINE}"

# --- (b) ... and the first boot after it dies between the grow and the mkfs ---
used_board
flash gpt empty
boot "${NO_MKFS}"
if [ "${RC}" -ne 0 ] && fills_disk; then
    ok "reflash, first boot cut short: stopped after the grow, before the mkfs"
else
    bad "reflash, first boot cut short: expected a failed boot with the partition grown (exit ${RC})"
    show_out
fi
boot
expect_new "reflash, first boot cut short: the next boot does not find the old filesystem" grown "carries no signature at all"

# --- (c) a reflash onto a board whose /data cannot grow -----------------------
used_board
flash gpt-tail empty
boot
expect_new "reflash, no room to grow: remade at the flashed size" flashed "${STALE_LINE}"

# --- (d) a healthy /data is kept ---------------------------------------------
used_board
boot
expect_kept "later boot: kept" "already fills"
dd if=/dev/urandom of="${LOOP}p1" bs=1M count=8 conv=notrunc status=none
boot
expect_kept "boot after another partition was rewritten (an A/B update): kept"

new_disk "${BIG_DISK}"
flash gpt fs
seed
boot
expect_kept "first boot, image with its own filesystem on a larger disk: kept"
if fills_disk && [ "$(fs_bytes)" -eq $((DATA_SIZE * MIB)) ]; then
    ok "first boot, image with its own filesystem on a larger disk: partition grown, filesystem untouched"
else
    bad "first boot, image with its own filesystem on a larger disk: partition $(part_bytes) bytes, filesystem $(fs_bytes)"
fi
boot
expect_kept "first boot cut short after the partition grew, before the filesystem resize: kept" "already fills"
e2fsck -fp "${DATA}" >/dev/null 2>&1
resize2fs "${DATA}" 150M >/dev/null 2>&1 || die "resize2fs could not grow the filesystem part of the way"
boot
expect_kept "first boot cut short part way through the filesystem resize: kept"
resize2fs "${DATA}" >/dev/null 2>&1 || die "resize2fs could not finish the grow"
boot
expect_kept "later boot once the resize has finished: kept"

new_disk "${IMAGE_SIZE}"
flash gpt fs
seed
boot
expect_kept "no room to grow, disk no larger than the image: kept" "already fills"

new_disk "${BIG_DISK}"
flash gpt-tail fs
seed
boot
expect_kept "no room to grow, a partition behind /data: kept" "did not grow"

# --- (e) the board that finds /data by its filesystem label -------------------
# The MBR table has no names, so root-disk-part finds nothing and the program
# falls back to the alias udev builds from the ext4 label.
new_disk "${BIG_DISK}"
flash dos fs
seed
rm -f "${WORK}/data-part"
mkdir -p /dev/wendyos
ln -sf "${DATA}" /dev/wendyos/data
boot
expect_kept "MBR board, first boot: kept"
fills_disk || die "the MBR board's /data did not grow"
e2fsck -fp "${DATA}" >/dev/null 2>&1
resize2fs "${DATA}" >/dev/null 2>&1 || die "resize2fs could not grow the MBR board's filesystem"
# The table back at its flashed sizes with the grown filesystem still under it.
# No flash leaves this board that way, because its image writes a filesystem of
# its own; it stands for whatever else might.
flash dos empty
boot
expect_kept "MBR board, filesystem larger than the partition: not erased ahead of the grow"
if [ "$(blkid -p -o value -s LABEL "${DATA}")" = data ]; then
    ok "MBR board, filesystem larger than the partition: the label the alias is built from is still there"
else
    bad "MBR board, filesystem larger than the partition: the label is gone, and with it the only name for /data"
fi

# --- (f) a reflash with encryption requested --------------------------------
# Without the erase, the identity carry cannot mount the old filesystem and the
# conversion stops there, leaving a plain /data at the flashed size.
used_board
flash gpt empty
arm_encryption
boot "${CRYPT}"
why=$(expect_converted)
case "${OUT}" in
    *"${STALE_LINE}"*"nothing to carry across the wipe"*) ;;
    *) why="${why:+$why, }the old filesystem was not erased before the identity carry" ;;
esac
fills_disk || why="${why:+$why, }the partition did not grow"
if [ -z "${why}" ]; then
    ok "reflash, encryption requested: the old filesystem is erased and the conversion goes on"
else
    bad "reflash, encryption requested: ${why}"
    show_out
fi

# --- (g) encryption requested on a used disk that was not reflashed ----------
used_board
arm_encryption
boot "${CRYPT}"
why=$(expect_converted)
case "${OUT}" in
    *"is being remade"*) why="${why:+$why, }a /data in use was erased" ;;
esac
carried=$(tar -xOf /config/backup/configuration.tar etc/wendyos/device-uuid 2>/dev/null)
[ "${carried}" = "0b9e8a52-old-installation" ] || why="${why:+$why, }the device identity was not carried to /config"
if [ -z "${why}" ]; then
    ok "encryption requested, no reflash: nothing erased, the identity is carried"
else
    bad "encryption requested, no reflash: ${why}"
    show_out
fi

# --- (h) the erase ends the boot, with an earlier attempt's marker on /config -
# data.mount is skipped while the marker exists, so a boot that ends before the
# conversion writes its own marker must not leave an old one behind.
used_board
flash gpt empty
arm_encryption
echo "left by an interrupted conversion" > /config/data.enroll.pending
boot "${NO_WIPEFS}:${CRYPT}"
why=""
[ "${RC}" -ne 0 ] || why="exit 0"
case "${OUT}" in
    *"wipefs could not erase it"*) ;;
    *) why="${why:+$why, }the erase did not end the boot" ;;
esac
grep -qx 'result=format_failed' /config/data.status 2>/dev/null \
    || why="${why:+$why, }data.status does not say format_failed"
[ ! -e /config/data.enroll.pending ] || why="${why:+$why, }the conversion marker was left behind"
if [ -z "${why}" ]; then
    ok "conversion ends at the erase: no marker is left behind"
else
    bad "conversion ends at the erase: ${why}"
    show_out
fi

echo
echo "passed: ${pass}, failed: ${fail}"
[ "${fail}" -eq 0 ]
