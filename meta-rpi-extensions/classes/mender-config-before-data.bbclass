# WendyOS RPi: place the FAT "config" extra partition BEFORE /data so that /data
# remains the LAST partition and can be grown to fill the card offline on first
# boot (no delete, no reboot) -- mirroring meta-tegra-extensions/classes/
# tegra_partition_config.bbclass, which keeps Tegra's data partition last.
#
# Mender's mender_part_image (meta-mender-core/classes/mender-part-images.bbclass)
# hard-codes "extra parts emitted AFTER /data"; there is no knob to reorder them,
# so we override the whole function. The body below is a VERBATIM copy of upstream
# mender_part_image() with EXACTLY ONE change: the get_extra_parts_wks() (config)
# emission is moved to BEFORE the /data (dataimg) emission.
#
# >>> MAINTENANCE: re-diff this function against upstream on every meta-mender
# >>> SRCREV bump. Synced from meta-mender @ 76404a7b.
#
# Numbering consequence (handled in raspberrypi-common-wendyos.inc): on the MBR
# sdimg this makes config the first logical (p5) and /data the last logical (p6),
# so MENDER_DATA_PART_NUMBER is overridden to 6 and the /config fstab line is
# label-based (number-agnostic).

mender_part_image() {
    suffix="$1"
    ptable_type="$2"
    boot_part_params="$3"

    set -ex

    mkdir -p "${WORKDIR}"

    if ${@bb.utils.contains('MENDER_FEATURES', 'mender-uboot', 'true', 'false', d)}; then
        # Copy the files to embed in the WIC image into ${WORKDIR} for exclusive access
        install -m 0644 "${DEPLOY_DIR_IMAGE}/uboot.env" "${WORKDIR}/"
    fi

    ondisk_dev="$(basename "${MENDER_STORAGE_DEVICE}")"

    wks="${WORKDIR}/mender-$suffix.wks"
    rm -f "$wks"
    if [ -n "${MENDER_IMAGE_BOOTLOADER_FILE}" ]; then
        # Copy the files to embed in the WIC image into ${WORKDIR} for exclusive access
        install -m 0644 "${DEPLOY_DIR_IMAGE}/${MENDER_IMAGE_BOOTLOADER_FILE}" "${WORKDIR}/"

        if [ $(expr ${MENDER_IMAGE_BOOTLOADER_BOOTSECTOR_OFFSET} % 2) -ne 0 ]; then
            # wic doesn't support fractions of kiB, so we need to do some tricks
            # when we are at an odd sector: Create a new bootloader file that
            # lacks the first 512 bytes, write that at the next even sector,
            # which coincides with a whole kiB, and then write the missing
            # sector manually afterwards.
            bootloader_sector=$(expr ${MENDER_IMAGE_BOOTLOADER_BOOTSECTOR_OFFSET} + 1)
            bootloader_file=${WORKDIR}/${MENDER_IMAGE_BOOTLOADER_FILE}-partial
            dd if=${WORKDIR}/${MENDER_IMAGE_BOOTLOADER_FILE} of=$bootloader_file skip=1
        else
            bootloader_sector=${MENDER_IMAGE_BOOTLOADER_BOOTSECTOR_OFFSET}
            bootloader_file=${WORKDIR}/${MENDER_IMAGE_BOOTLOADER_FILE}
        fi
        bootloader_align_kb=$(expr $(expr $bootloader_sector \* 512) / 1024)
        bootloader_size=$(stat -c '%s' "$bootloader_file")
        bootloader_end=$(expr $bootloader_align_kb \* 1024 + $bootloader_size)
        if [ $bootloader_end -gt ${MENDER_UBOOT_ENV_STORAGE_DEVICE_OFFSET} ]; then
            bberror "Size of bootloader specified in MENDER_IMAGE_BOOTLOADER_FILE" \
                    "exceeds MENDER_UBOOT_ENV_STORAGE_DEVICE_OFFSET, which is" \
                    "reserved for U-Boot environment storage. Please raise it" \
                    "manually."
        fi
        cat >> "$wks" <<EOF
# embed bootloader
part --source rawcopy --sourceparams="file=$bootloader_file" --ondisk "$ondisk_dev" --align $bootloader_align_kb --no-table
EOF
    fi

    if ${@bb.utils.contains('MENDER_FEATURES', 'mender-uboot', 'true', 'false', d)} && [ -n "${MENDER_UBOOT_ENV_STORAGE_DEVICE_OFFSET}" ]; then
        boot_env_align_kb=$(expr ${MENDER_UBOOT_ENV_STORAGE_DEVICE_OFFSET} / 1024)
        cat >> "$wks" <<EOF
part --source rawcopy --sourceparams="file=${WORKDIR}/uboot.env" --ondisk "$ondisk_dev" --align $boot_env_align_kb --no-table
EOF
    fi

    if [ $(expr ${MENDER_PARTITION_ALIGNMENT} % 1024 || true) -ne 0 ]; then
        bbfatal "MENDER_PARTITION_ALIGNMENT must be KiB aligned when using partition table."
    fi

    alignment_kb=$(expr ${MENDER_PARTITION_ALIGNMENT} / 1024)

    # Used for all Linux filesystem partitions.
    if [ "$ptable_type" = "gpt" ]; then
        part_type_params="--part-type 0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    else
        part_type_params=
    fi

    # remove leading and trailing spaces
    IMAGE_BOOT_FILES_STRIPPED=$(echo "${IMAGE_BOOT_FILES}" | sed -r 's/(^\s*)|(\s*$)//g')

    if [ "${MENDER_BOOT_PART_SIZE_MB}" -ne "0" ]; then
        cat >> "$wks" <<EOF
part --source rawcopy --sourceparams="file=${IMGDEPLOYDIR}/${IMAGE_LINK_NAME}.bootimg" --ondisk "$ondisk_dev" --align $alignment_kb --fixed-size ${MENDER_BOOT_PART_SIZE_MB} --active $boot_part_params
EOF
    elif [ -n "$IMAGE_BOOT_FILES_STRIPPED" ]; then
        bbwarn "MENDER_BOOT_PART_SIZE_MB is set to zero, but IMAGE_BOOT_FILES is not empty. The files are being omitted from the image."
    fi

    # By default the inactive partition filesystem is empty to allow for more efficient compression.
    # A full filesystem is populated if one of the following applies
    # - ARTIFACTIMG_FSTYPE is squashfs, because it doesn not allow empty partitions.
    # - the "mender-prepopulate-inactive-partition" MENDER_FEATURE is enabled
    if [ "${ARTIFACTIMG_FSTYPE}" = "squashfs" ] || ${@bb.utils.contains('MENDER_FEATURES', 'mender-prepopulate-inactive-partition', 'true', 'false', d)}; then
        part2_content="--source rawcopy --sourceparams=\"file=${IMGDEPLOYDIR}/${IMAGE_LINK_NAME}.${ARTIFACTIMG_FSTYPE}\""
    else
        part2_content=
    fi
    cat >> "$wks" <<EOF
part --source rawcopy --sourceparams="file=${IMGDEPLOYDIR}/${IMAGE_LINK_NAME}.${ARTIFACTIMG_FSTYPE}" --ondisk "$ondisk_dev" --align $alignment_kb --fixed-size ${MENDER_CALC_ROOTFS_SIZE}k $part_type_params
part $part2_content --ondisk "$ondisk_dev" --fstype=${ARTIFACTIMG_FSTYPE} --align $alignment_kb --fixed-size ${MENDER_CALC_ROOTFS_SIZE}k $part_type_params
EOF

    if [ "${MENDER_SWAP_PART_SIZE_MB}" -ne "0" ]; then
        cat >> "$wks" <<EOF
part swap --ondisk "$ondisk_dev" --fstype=swap --label swap --align $alignment_kb --size ${MENDER_SWAP_PART_SIZE_MB}
EOF
    fi

    # added extra partitions if exists
    cat >> "$wks" <<EOF
${@get_extra_parts_wks(d)}
EOF
    cat >> "$wks" <<EOF
part --source rawcopy --sourceparams="file=${IMGDEPLOYDIR}/${IMAGE_LINK_NAME}.dataimg" --ondisk "$ondisk_dev" --align $alignment_kb --fixed-size ${MENDER_DATA_PART_SIZE_MB} $part_type_params
EOF

    cat >> "$wks" <<EOF
bootloader --ptable $ptable_type
EOF


    echo "### Contents of wks file ###"
    cat "$wks"
    echo "### End of contents of wks file ###"

    # Call WIC
    outimgname="${IMGDEPLOYDIR}/${IMAGE_NAME}.$suffix"
    wicout="${IMGDEPLOYDIR}/${IMAGE_NAME}-$suffix"
    BUILDDIR="${TOPDIR}" wic create "$wks" --vars "${STAGING_DIR}/${MACHINE}/imgdata/" -e "${IMAGE_BASENAME}" -o "$wicout/" ${WIC_CREATE_EXTRA_ARGS}

    # look to see if the user specifies a custom imager
    IMAGER=direct
    eval set -- "${WIC_CREATE_EXTRA_ARGS} --"
    while [ 1 ]; do
            case "$1" in
                    --imager|-i)
                            shift
                            IMAGER=$1
                            ;;
                    --)
                            shift
                            break
                            ;;
            esac
            shift
    done
    mv "$wicout/$(basename "${wks%.wks}")"*.${IMAGER} "$outimgname"

    if [ -n "${MENDER_IMAGE_BOOTLOADER_FILE}" ] && [ ${MENDER_IMAGE_BOOTLOADER_BOOTSECTOR_OFFSET} -ne $bootloader_sector ]; then
        # We need to write the first sector of the bootloader. See comment above
        # where bootloader_sector is set.
        dd if=${WORKDIR}/${MENDER_IMAGE_BOOTLOADER_FILE} of="$outimgname" seek=${MENDER_IMAGE_BOOTLOADER_BOOTSECTOR_OFFSET} count=1 conv=notrunc
    fi

    if [ -n "${MENDER_MBR_BOOTLOADER_FILE}" ]; then
        dd if="${DEPLOY_DIR_IMAGE}/${MENDER_MBR_BOOTLOADER_FILE}" of="$outimgname" bs=${MENDER_MBR_BOOTLOADER_LENGTH} count=1 conv=notrunc
    fi

    rm -rf "$wicout/"

    # Pad the image up to the alignment. This matters mostly for the emulator,
    # which uses the file size to determine the size of the storage device,
    # which must be a multiple of its device block size. However, it might be
    # beneficial for real storage media as well, to make sure the final sector
    # is cleared out when flashing the image. May increase image size slightly,
    # but should compress well!
    alignment=${MENDER_PARTITION_ALIGNMENT}
    pad_size=$(expr \( $(stat -c %s "$outimgname") + $alignment - 1 \) / $alignment \* $alignment)
    truncate -s $pad_size "$outimgname"

    # If we padded above, and the partition table type is GPT, we need to
    # relocate the trailing backup header to the new end to avoid warnings.
    if [ "$ptable_type" = "gpt" ]; then
        sgdisk -e "$outimgname"
    fi

    if [ "$ptable_type" = "msdos" ]; then
        # Fix partition entry types for MBR style partition table.
        (
            echo t                                  # Partition type
            echo ${MENDER_ROOTFS_PART_A_NUMBER}     # Number of partition
            echo 83                                 # "Linux filesystem" type

            echo t                                  # Partition type
            echo ${MENDER_ROOTFS_PART_B_NUMBER}     # Number of partition
            echo 83                                 # "Linux filesystem" type

            echo t                                  # Partition type
            echo ${MENDER_DATA_PART_NUMBER}         # Number of partition
            echo 83                                 # "Linux filesystem" type

            echo w                                  # Save and exit
        ) | fdisk ${outimgname}
    fi

    if ${@bb.utils.contains('MENDER_FEATURES', 'mender-partuuid', 'true', 'false', d)}; then
        if [ "$ptable_type" = "gpt" ]; then
            # Set Fixed PARTUUID for all devices
            sgdisk -u ${MENDER_BOOT_PART_NUMBER}:${@mender_get_partuuid_from_device(d, '${MENDER_BOOT_PART}')} "$outimgname"
            sgdisk -u ${MENDER_ROOTFS_PART_A_NUMBER}:${@mender_get_partuuid_from_device(d, '${MENDER_ROOTFS_PART_A}')} "$outimgname"
            sgdisk -u ${MENDER_ROOTFS_PART_B_NUMBER}:${@mender_get_partuuid_from_device(d, '${MENDER_ROOTFS_PART_B}')} "$outimgname"
            sgdisk -u ${MENDER_DATA_PART_NUMBER}:${@mender_get_partuuid_from_device(d, '${MENDER_DATA_PART}')} "$outimgname"
	    # check if we have extra parts and setup uuid for those partitions
	    local ext_partitions="${@get_extra_parts_partition_to_uuid(d)}"
	    for part in ${ext_partitions}; do
		sgdisk -u ${part} "$outimgname"
	    done

        else
            diskIdent=$(echo ${@mender_get_partuuid_from_device(d, '${MENDER_ROOTFS_PART_A}')} | cut -d- -f1)
            # For MBR Set the Disk Identifier.  Drives follow the pattern of <Disk Identifier>-<Part Number>
            (
                echo x                              # Enter expert mode
                echo i                              # Set disk identifier
                echo 0x${diskIdent}                 # Identifier
                echo r                              # Exit expert mode
                echo w                              # Write changes
            ) | fdisk ${outimgname}
        fi
    fi
}
