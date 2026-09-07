SUMMARY = "Qualcomm NPU (QAIRT/QNN) userspace as a systemd-sysext add-on"
DESCRIPTION = "Packs the Qualcomm AI Runtime userspace into a squashfs add-on merged \
onto /usr at runtime, so the NPU stack can be installed, updated and rolled back \
without rebuilding the OS image. The DSP platform half stays in the rootfs: remoteproc \
loads the DSP firmware early in boot, and the Hexagon shell it authorises has to be \
there with it."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit image

# The payload is the SoC's DSP userspace; never shared between machines.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# systemd merges <name>.raw only if it carries extension-release.<name>, matched by
# exact suffix, so the image filename and this cannot be allowed to drift. The version
# goes inside the image, not in the filename.
WENDYOS_SYSEXT_NAME = "wendyos-qcom-npu"

# The NPU userspace half, and only that. The Hexagon shell and the DSP base runtime
# are authorised by the signed DSP firmware and ship in the rootfs alongside it -- see
# packagegroup-wendyos-qcom. The QNN skels here are loaded into an already-authorised
# unsigned PD, so they carry no firmware lock and are free to be updated on their own.
# fastrpc-tests rides along rather than sitting in the rootfs: dsp_check and
# fastrpc_test are how the add-on is validated on a device, and a base image has no
# use for them once the add-on is gone.
WENDYOS_SYSEXT_PAYLOAD = "qairt-sdk qairt-sdk-hexagon-v75 fastrpc-tests"

# coreutils is not payload. qairt-sdk's converter scripts carry a "#!/usr/bin/env"
# shebang, which rpm turns into a file dependency; the base OS satisfies it at runtime
# but a payload-only rootfs has nothing providing /usr/bin/env, and the solver refuses
# to install. It is pruned away again, so it never reaches the image.
IMAGE_INSTALL = "${WENDYOS_SYSEXT_PAYLOAD} coreutils"
IMAGE_FEATURES = ""
IMAGE_LINGUAS = ""

# qairt-sdk recommends the hexagon skels for every other SoC too. The payload names the
# one this board can run, and the rest would only be built and then pruned away.
NO_RECOMMENDATIONS = "1"

# Sizing is for block images; a squashfs is written to fit.
IMAGE_ROOTFS_SIZE = "0"
IMAGE_OVERHEAD_FACTOR = "1.0"

# systemd compares ARCHITECTURE against its own identifiers, which match neither the
# kernel's names nor Yocto's.
WENDYOS_SYSEXT_ARCH = "${@{'aarch64': 'arm64'}.get(d.getVar('TARGET_ARCH'), '')}"

# Hooked into do_image, not do_rootfs: a recipe's "+=" on ROOTFS_POSTPROCESS_COMMAND
# is applied before the class's, so a prune there runs first and the systemd and
# shadow postcommands put /etc back behind it. do_image runs after all of do_rootfs,
# and :append keeps these last within it.
IMAGE_PREPROCESS_COMMAND:append = " wendyos_sysext_prune_to_payload; wendyos_sysext_write_release;"

# A merged add-on's /usr is stacked over the host's, so every file here that the base OS
# also owns -- glibc, libstdc++, base-files -- would shadow the host's own copy. Only the
# payload's files may survive. The list comes from pkgdata rather than a glob, so it
# tracks whatever the payload recipes actually package.
python wendyos_sysext_prune_to_payload () {
    import json
    import os
    import oe.packagedata

    rootfs = d.getVar('IMAGE_ROOTFS')

    keep = set()
    for pkg in d.getVar('WENDYOS_SYSEXT_PAYLOAD').split():
        recorded = oe.packagedata.read_subpkgdata_dict(pkg, d).get('FILES_INFO')
        if not recorded:
            bb.fatal("%s packages no files; the add-on would ship empty" % pkg)
        keep.update(json.loads(recorded))

    # Directories on the way to a kept file have to stay even when no package claims
    # them, or the file has nowhere to live.
    needed_dirs = set()
    for path in keep:
        parent = os.path.dirname(path)
        while parent not in ('/', ''):
            needed_dirs.add(parent)
            parent = os.path.dirname(parent)

    def target(path):
        return '/' + os.path.relpath(path, rootfs)

    removed = 0
    for root, dirs, files in os.walk(rootfs, topdown=False):
        for name in files:
            path = os.path.join(root, name)
            if target(path) not in keep:
                os.unlink(path)
                removed += 1
        # Each name is handled once. os.walk lists a symlinked directory under dirs,
        # but to the payload it is a file, so it is matched against the file list and
        # unlinked -- never rmdir'd, and never descended into.
        for name in dirs:
            path = os.path.join(root, name)
            if os.path.islink(path):
                if target(path) not in keep:
                    os.unlink(path)
                    removed += 1
            elif target(path) not in keep and target(path) not in needed_dirs:
                os.rmdir(path)

    bb.note("%s: kept %d payload files, dropped %d from the dependency closure"
            % (d.getVar('WENDYOS_SYSEXT_NAME'), len(keep), removed))
}

# The compatibility contract. systemd only reads ID/SYSEXT_LEVEL/ARCHITECTURE and
# ignores unknown keys, so the WENDYOS_* fields are ours to describe what the add-on
# was built against.
#
# SYSEXT_LEVEL rather than VERSION_ID: systemd compares SYSEXT_LEVEL when host and
# add-on both declare one, and matching on VERSION_ID would unmerge every add-on on
# each OS patch.
#
# No WENDYOS_KERNEL field: the payload is userspace and talks to the kernel only
# through the FastRPC character device, so it survives a kernel bump and belongs in
# the store's kernel-independent bucket.
python wendyos_sysext_write_release () {
    import os
    import oe.packagedata

    arch = d.getVar('WENDYOS_SYSEXT_ARCH')
    if not arch:
        bb.fatal("no systemd architecture name known for TARGET_ARCH '%s'"
                 % d.getVar('TARGET_ARCH'))

    qairt = oe.packagedata.read_subpkgdata_dict('qairt-sdk', d).get('PKGV')
    if not qairt:
        bb.fatal("cannot read qairt-sdk's version from pkgdata")

    name = d.getVar('WENDYOS_SYSEXT_NAME')
    fields = [
        ('ID', d.getVar('DISTRO')),
        ('SYSEXT_LEVEL', d.getVar('WENDYOS_SYSEXT_LEVEL')),
        ('ARCHITECTURE', arch),
        ('EXTENSION_RELOAD_MANAGER', '1'),
        ('WENDYOS_EXTENSION', 'qcom-npu'),
        ('WENDYOS_EXTENSION_VERSION', d.getVar('PV')),
        ('WENDYOS_EXTENSION_BUILT_FOR_OS', d.getVar('DISTRO_VERSION')),
        ('WENDYOS_EXTENSION_SOC', 'qcs8300'),
        ('WENDYOS_EXTENSION_DSP_ARCH', 'v75'),
        ('WENDYOS_EXTENSION_QAIRT_VERSION', qairt),
    ]

    reldir = d.expand('${IMAGE_ROOTFS}${nonarch_libdir}/extension-release.d')
    bb.utils.mkdirhier(reldir)
    with open(os.path.join(reldir, 'extension-release.' + name), 'w') as f:
        f.write(''.join('%s=%s\n' % kv for kv in fields))
}

IMAGE_FSTYPES = "wendyos-sysext"
do_image_wendyos_sysext[depends] += "squashfs-tools-native:do_populate_sysroot"

IMAGE_CMD:wendyos-sysext () {
	# Deterministic output: mksquashfs otherwise stamps the build time into the
	# superblock and every mtime, so an unchanged payload republishes under a new
	# checksum. oe_mksquashfs reads the rootfs mtime instead, which the prune above
	# has already moved.
	export SOURCE_DATE_EPOCH=${REPRODUCIBLE_TIMESTAMP_ROOTFS}
	mksquashfs ${IMAGE_ROOTFS} ${IMGDEPLOYDIR}/${WENDYOS_SYSEXT_NAME}.raw \
		-noappend -no-progress -all-root -comp xz
}

COMPATIBLE_MACHINE = "iq-8275-evk-wendyos"
