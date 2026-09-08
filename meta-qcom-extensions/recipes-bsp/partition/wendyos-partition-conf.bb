SUMMARY = "WendyOS A/B partition tables for Qualcomm Dragonwing"
DESCRIPTION = "Generates the GPT binaries and QDL flashing scripts for the WendyOS \
A/B layout (efi + config + rootfsA + rootfsB + data) from files/partitions.conf, \
using meta-qcom's qcom-ptool. Replaces upstream qcom-partition-conf, which ships a \
pre-generated single-rootfs layout; select it with \
QCOM_PARTITION_CONF = \"wendyos-partition-conf\" in the machine conf."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://partitions.conf"
S = "${UNPACKDIR}"

DEPENDS = "qcom-ptool-native"

inherit deploy

COMPATIBLE_MACHINE = "iq-8275-evk-wendyos"

# The GPT is machine-specific: slot sizes come from WENDYOS_ROOTFS_SIZE_KB and it
# deploys under ${MACHINE}. Not allarch, or one machine's layout would be reused
# from another's sstate.
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install[noexec] = "1"

# Must match where image_types_qcom looks for these files, or the flash package
# ships without a GPT.
WENDYOS_PARTITION_SUBDIR ?= "${QCOM_PARTITION_FILES_SUBDIR}"

# Fail loudly at build time if the declared slot size and the pinned rootfs size
# ever drift apart. Silent drift would produce an image that does not fit its slot
# and would only surface as a corrupt device after flashing.
do_compile[vardeps] += "WENDYOS_ROOTFS_SIZE_KB"
do_compile() {
    conf="${UNPACKDIR}/partitions.conf"

    for slot in rootfsA rootfsB; do
        declared=$(sed -n "s/.*--name=${slot} --size=\([0-9]*\)KB.*/\1/p" "${conf}")
        if [ -z "${declared}" ]; then
            bbfatal "wendyos-partition-conf: no --size found for ${slot} in partitions.conf"
        fi
        if [ "${declared}" != "${WENDYOS_ROOTFS_SIZE_KB}" ]; then
            bbfatal "wendyos-partition-conf: ${slot} is ${declared}KB but WENDYOS_ROOTFS_SIZE_KB is ${WENDYOS_ROOTFS_SIZE_KB}KB; the A/B slot must equal the pinned rootfs image size exactly"
        fi
    done

    install -d ${B}/out
    cd ${B}/out
    cp "${conf}" .
    qcom-ptool gen_partition -i partitions.conf -o partitions.xml
    qcom-ptool ptool -x partitions.xml
}

do_deploy() {
    install -d ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}
    # image_types_qcom's deploy_partition_files() globs only gpt_{main,backup,both}*.bin,
    # zeros_*.bin, rawprogram[0-9].xml and patch*.xml, so the empty-GPT and wipe
    # helpers below reach DEPLOY_DIR_IMAGE for manual qdl recovery but not the tarball.
    # LUN 0 exists here by design (see partitions.conf), so nothing can write the
    # firmware LUNs.
    install -m 0644 ${B}/out/gpt_main0.bin      ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}/
    install -m 0644 ${B}/out/gpt_backup0.bin    ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}/
    install -m 0644 ${B}/out/gpt_both0.bin      ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}/
    install -m 0644 ${B}/out/gpt_empty0.bin     ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}/
    install -m 0644 ${B}/out/rawprogram0.xml    ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}/
    install -m 0644 ${B}/out/patch0.xml         ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}/
    install -m 0644 ${B}/out/zeros_*.bin        ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}/
    # Recovery/erase helpers ptool emits alongside the main scripts.
    install -m 0644 ${B}/out/rawprogram0_BLANK_GPT.xml       ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}/
    install -m 0644 ${B}/out/rawprogram0_WIPE_PARTITIONS.xml ${DEPLOYDIR}/${WENDYOS_PARTITION_SUBDIR}/
}

addtask deploy after do_compile before do_build
