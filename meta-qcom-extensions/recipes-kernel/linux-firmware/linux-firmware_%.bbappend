# Hand the Intel driver add-on's selected firmware files to the kernel devkit.

WENDYOS_DRIVER_DEVKIT_FIRMWARE ?= ""

# linux-firmware deliberately excludes its payload from the sysroot. Export
# only the optional driver bundle's selected files for the kernel devkit.
python __anonymous() {
    if d.getVar('WENDYOS_DRIVER_DEVKIT_FIRMWARE'):
        d.appendVar('SYSROOT_PREPROCESS_FUNCS', ' wendyos_stage_driver_firmware')
}

wendyos_stage_driver_firmware() {
    for firmware in ${WENDYOS_DRIVER_DEVKIT_FIRMWARE}; do
        source=${D}${nonarch_base_libdir}/firmware/$firmware
        [ -f "$source" ] || bbfatal "driver firmware is missing: $firmware"
        install -D -m 0644 "$source" \
            ${SYSROOT_DESTDIR}/sysroot-only/wendyos-driver-firmware/$firmware
    done
}
