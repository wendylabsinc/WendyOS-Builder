SUMMARY = "Self-contained kernel build tree + toolchain for out-of-tree driver builds"
DESCRIPTION = "Packs the kernel source subset, the build artifacts, the cross toolchain \
and the loader they were linked against into one relocatable tarball, so a driver module \
can be compiled with no build system present. The tarball is the contract between the OS \
build and the driver pipeline: whatever produces it can host driver builds."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

inherit nopackages deploy

# Tracks one machine's kernel; never shared between machines.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Same mapping kernel.bbclass and module.bbclass use, so a devkit build and an in-tree
# module build cannot disagree about the arch directory name.
KARCH = "${@oe.kernel.map_kernel_arch(d)}"

# Every other input is staged by another recipe, so there is nothing to fetch or build.
SRC_URI = "file://setup.sh"
S = "${UNPACKDIR}"
INHIBIT_DEFAULT_DEPS = "1"
# openssl-native: sign-file links against libcrypto and is copied out of this recipe's
# own sysroot below.
DEPENDS = "virtual/cross-cc virtual/cross-binutils zstd-native squashfs-tools-native openssl-native"

do_configure[noexec] = "1"

# The kernel source and build artifacts come from do_shared_workdir; Module.symvers only
# appears once the in-tree modules are built; make-mod-scripts compiles the host kbuild
# binaries under build-artifacts/scripts.
do_compile[depends] += "virtual/kernel:do_shared_workdir"
do_compile[depends] += "virtual/kernel:do_compile_kernelmodules"
do_compile[depends] += "make-mod-scripts:do_configure"

DEVKIT_ROOT = "${WORKDIR}/devkit"
DEVKIT_KBUILD = "${DEVKIT_ROOT}/kernel-build"
UNINATIVE_SYSROOT = "${UNINATIVE_STAGING_DIR}-uninative/${BUILD_ARCH}-linux"

do_compile() {
    rm -rf ${DEVKIT_ROOT}
    install -d ${DEVKIT_KBUILD} ${DEVKIT_ROOT}/toolchain ${DEVKIT_ROOT}/hosttools \
               ${DEVKIT_ROOT}/runtime/lib ${DEVKIT_ROOT}/runtime/usr/lib

    kver=$(cat ${STAGING_KERNEL_BUILDDIR}/kernel-abiversion)
    if [ -z "$kver" ]; then
        bbfatal "kernel-abiversion is empty; the devkit has no key to be named after"
    fi
    karch="${KARCH}"

    # --- kernel source subset ----------------------------------------------------
    # Only what kbuild opens when building an external module; the full tree is far larger.
    (
        cd ${STAGING_KERNEL_DIR}
        find . -type f \( -name 'Makefile*' -o -name 'Kbuild*' -o -name 'Kconfig*' \) \
            -print0 | xargs -0 cp --parents --target-directory=${DEVKIT_KBUILD}
        cp -a --parents scripts include "arch/$karch/include" ${DEVKIT_KBUILD}/
        cp -a --parents "arch/$karch/kernel/vdso/vdso.lds" ${DEVKIT_KBUILD} 2>/dev/null || :
        if [ -e ${STAGING_KERNEL_BUILDDIR}/tools/objtool/objtool ]; then
            cp -a --parents tools/objtool tools/build tools/lib tools/include tools/scripts \
                ${DEVKIT_KBUILD}/
        fi
    )

    # --- build artifacts, overlaid on the source ---------------------------------
    # Unified source and object tree, so a consumer needs no O=. This block must run after
    # the source copy: generated headers and host-built scripts have to land on top of it.
    # certs/ is excluded — it holds the private signing key, and only the public
    # certificate may go into a distributed artifact.
    (
        cd ${STAGING_KERNEL_BUILDDIR}
        cp -a --parents scripts include arch ${DEVKIT_KBUILD}/
        cp -a .config kernel-abiversion kernel-localversion ${DEVKIT_KBUILD}/
        cp -a System.map* ${DEVKIT_KBUILD}/ 2>/dev/null || :
        [ -e tools/objtool/objtool ] && cp -a --parents tools/objtool/objtool ${DEVKIT_KBUILD}/ || :
    )

    # The public cert, so a consumer can confirm which key a signed module should carry.
    if [ -e ${STAGING_KERNEL_BUILDDIR}/certs/signing_key.x509 ]; then
        install -D -m 0644 ${STAGING_KERNEL_BUILDDIR}/certs/signing_key.x509 \
            ${DEVKIT_ROOT}/certs/signing_key.x509
    fi

    # With MODVERSIONS on, symbol CRCs decide whether a module loads, so a devkit without
    # this file yields modules insmod rejects. It appears only at the end of
    # do_compile_kernelmodules, hence the dependency on that task.
    if [ ! -e ${STAGING_KERNEL_BUILDDIR}/Module.symvers ]; then
        bbfatal "Module.symvers absent; a devkit without it produces unloadable modules"
    fi
    cp -a ${STAGING_KERNEL_BUILDDIR}/Module.symvers ${DEVKIT_KBUILD}/

    # Missing any of these still packs cleanly and then fails deep inside kbuild on the
    # consumer, with an error that names nothing useful.
    for required in \
            "${DEVKIT_KBUILD}/arch/$karch/include/asm" \
            "${DEVKIT_KBUILD}/include/linux" \
            "${DEVKIT_KBUILD}/scripts/mod/modpost" \
            "${DEVKIT_KBUILD}/scripts/basic/fixdep" \
            "${DEVKIT_KBUILD}/.config"; do
        [ -e "$required" ] || bbfatal "devkit incomplete: missing $required"
    done

    # sign-file exists only when the kernel enables module signing, which is per machine.
    if grep -q '^CONFIG_MODULE_SIG=y' ${DEVKIT_KBUILD}/.config; then
        [ -e "${DEVKIT_KBUILD}/scripts/sign-file" ] \
            || bbfatal "devkit incomplete: kernel signs modules but scripts/sign-file is missing"
    fi

    # Absolute paths from this build would send a consumer's kbuild looking in
    # directories that do not exist on its machine.
    rm -f ${DEVKIT_KBUILD}/source ${DEVKIT_KBUILD}/build
    find ${DEVKIT_KBUILD} -name '*.cmd' -delete
    # Only the loose objects beside the host tools; a blanket *.o sweep would remove
    # objects kbuild links against.
    rm -f ${DEVKIT_KBUILD}/scripts/*.o ${DEVKIT_KBUILD}/scripts/*/*.o

    # --- cross toolchain ---------------------------------------------------------
    (
        cd ${STAGING_DIR_NATIVE}
        for d in usr/bin/${TARGET_SYS} usr/libexec/${TARGET_SYS} usr/lib/${TARGET_SYS}; do
            [ -d "$d" ] && cp -a --parents "$d" ${DEVKIT_ROOT}/toolchain/ || :
        done
    )

    # Packing an add-on needs mksquashfs; shipping it keeps the devkit the only thing a
    # driver build depends on.
    install -m 0755 ${STAGING_DIR_NATIVE}${bindir}/mksquashfs ${DEVKIT_ROOT}/hosttools/

    # --- the libraries those binaries were linked against -------------------------
    # Two directories, because the relocated loader searches both <prefix>/lib (uninative's
    # glibc, which every native binary's ELF interpreter points at) and <prefix>/usr/lib
    # (the toolchain's own libraries, which cc1 and ld need beyond glibc). Copied whole
    # rather than as a computed closure, which would fail later inside kbuild if short.
    cp -a ${UNINATIVE_SYSROOT}/lib/*.so* ${DEVKIT_ROOT}/runtime/lib/
    cp -a ${STAGING_DIR_NATIVE}/usr/lib/*.so* ${DEVKIT_ROOT}/runtime/usr/lib/ 2>/dev/null || :
    rm -rf ${DEVKIT_ROOT}/runtime/lib/.debug ${DEVKIT_ROOT}/runtime/usr/lib/.debug

    # The SDK's own interpreter patcher, taken from the tree being built so it cannot
    # drift from the binaries it has to patch.
    install -m 0755 ${COREBASE}/scripts/relocate_sdk.py ${DEVKIT_ROOT}/relocate_sdk.py
    install -m 0755 ${UNPACKDIR}/setup.sh ${DEVKIT_ROOT}/setup.sh

    # --- manifest ----------------------------------------------------------------
    # kernel_version is uname -r, taken from the kernel's generated abiversion file. It is
    # the whole key — page size and LOCALVERSION are already part of it — and is what the
    # publisher, the agent and insmod all compare.
    # Indented one space: bitbake ends a shell function at the first '}' in column 0 and
    # cannot tell that this one is inside a heredoc.
    cat > ${DEVKIT_ROOT}/devkit.json <<EOF
 {
   "machine": "${MACHINE}",
   "kernel_version": "$kver",
   "arch": "$karch",
   "cross_compile": "${TARGET_PREFIX}",
   "toolchain_bindir": "toolchain/usr/bin/${TARGET_SYS}",
   "original_loader": "${UNINATIVE_LOADER}",
   "os_id": "${DISTRO}",
   "sysext_level": "${WENDYOS_SYSEXT_LEVEL}"
 }
EOF

    # The certs/ exclusion above is easy to undo by accident, so enforce the invariant
    # here. -I skips binaries, which carry "BEGIN ... PRIVATE KEY" as PEM parser strings.
    leaked=$(grep -rlIE 'BEGIN( [A-Z]+)* PRIVATE KEY' ${DEVKIT_ROOT} 2>/dev/null || true)
    if [ -n "$leaked" ]; then
        bbfatal "private key material in the devkit, refusing to pack: $leaked"
    fi
}

do_deploy() {
    kver=$(cat ${DEVKIT_KBUILD}/kernel-abiversion)
    tar --create --file ${DEPLOYDIR}/wendyos-kernel-devkit-${MACHINE}-$kver.tar.zst \
        --use-compress-program="zstd -10 -T0" \
        --directory ${DEVKIT_ROOT} .
}
addtask deploy after do_compile before do_build
