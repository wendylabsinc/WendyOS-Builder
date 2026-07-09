SRC_URI:append:x86-wendyos = " \
    https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/WIFI_RAM_CODE_MT7961_1a.bin;name=mt7920ram \
    https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/WIFI_MT7961_patch_mcu_1a_2_hdr.bin;name=mt7920patch \
    "

SRC_URI[mt7920ram.sha256sum] = "3edec74ffe341b917e7fa4ddb2b68851411f2416555f10619a5900fa4b141e6c"
SRC_URI[mt7920patch.sha256sum] = "a766c4e39815e554c80ce5b1596095ff283a60db93356679fecd6494f71cee23"

do_install:append:x86-wendyos() {
    install -d ${D}${nonarch_base_libdir}/firmware/mediatek
    install -m 0644 ${UNPACKDIR}/WIFI_RAM_CODE_MT7961_1a.bin ${D}${nonarch_base_libdir}/firmware/mediatek/
    install -m 0644 ${UNPACKDIR}/WIFI_MT7961_patch_mcu_1a_2_hdr.bin ${D}${nonarch_base_libdir}/firmware/mediatek/
}

FILES:${PN}-mediatek:append:x86-wendyos = " \
    ${nonarch_base_libdir}/firmware/mediatek/WIFI_RAM_CODE_MT7961_1a.bin \
    ${nonarch_base_libdir}/firmware/mediatek/WIFI_MT7961_patch_mcu_1a_2_hdr.bin \
    "
