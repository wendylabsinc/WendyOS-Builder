# Image check shared by the boards whose fstab mounts /dev/wendyos/<name> links
# (Raspberry Pi and Rockchip). Inherited by wendyos-image on those boards.

# Every /dev/wendyos/<name> that fstab mounts needs a udev rule in the image
# that creates it. Without the rule the mount never happens and nothing fails.
check_wendyos_links() {
    links_fstab="${IMAGE_ROOTFS}${sysconfdir}/fstab"
    if [ ! -f "$links_fstab" ]; then
        return 0
    fi

    # find fails on a missing directory, which under set -e ends the task
    # without a message, so pass it only the directories that exist.
    set --
    for links_dir in "${IMAGE_ROOTFS}${sysconfdir}/udev/rules.d" \
                     "${IMAGE_ROOTFS}${nonarch_base_libdir}/udev/rules.d"; do
        if [ -d "$links_dir" ]; then
            set -- "$@" "$links_dir"
        fi
    done

    links_names=$(awk '$1 ~ /^\/dev\/wendyos\// { print substr($1, 14) }' "$links_fstab")
    for links_name in $links_names; do
        links_rule=""
        if [ "$#" -gt 0 ]; then
            links_rule=$(find "$@" -type f -name '*.rules' -exec awk -v s="SYMLINK+=\"wendyos/$links_name\"" '
                !/^[ \t]*#/ && index($0, s) { print FILENAME; exit }
            ' {} +)
        fi
        if [ -z "$links_rule" ]; then
            bbfatal "check_wendyos_links: ${sysconfdir}/fstab mounts /dev/wendyos/$links_name," \
                    "but no uncommented line of a .rules file under ${sysconfdir}/udev/rules.d or" \
                    "${nonarch_base_libdir}/udev/rules.d contains SYMLINK+=\"wendyos/$links_name\"," \
                    "so the mount would never happen. Is the rule's recipe installed for this machine?"
        fi
    done
}
ROOTFS_POSTPROCESS_COMMAND += "check_wendyos_links"
